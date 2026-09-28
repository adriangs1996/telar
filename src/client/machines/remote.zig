//! `telar --remote <destination>`: attach the local client to the runtime on
//! an SSH host by forwarding its Unix socket to a private local one. The
//! wire protocol, framing and backpressure are unchanged; the client simply
//! connects to the forwarded socket, and shared-memory graphics are disabled
//! because the runtime lives on another machine.

const core = @import("telar-core");
const localsocket = @import("localsocket");
const std = @import("std");
const Forward = @import("Forward.zig");
const RuntimeConnector = @import("RuntimeConnector.zig");
const Discovery = @import("Discovery.zig");
const remote_discovery = @import("remote_discovery.zig");
const SshOptions = @import("SshOptions.zig");
const RemoteMachine = @import("RemoteMachine.zig");

pub const connect_attempts = 100;
pub const connect_interval_ms = 100;

/// The largest `telar api schema --json` output read back, in bytes.
const schema_output_limit = 256 * 1024;

const endpoint_timeout: std.Io.Timeout = .{
    .duration = .{ .clock = .awake, .raw = .fromSeconds(30) },
};

/// Discovers the remote home, shell and runtime socket over SSH, then starts
/// one `ssh -L` forward and waits until its private socket exists. The
/// socket's name carries the destination and the window slot, so two
/// windows on one machine never share or remove each other's socket. SSH's
/// error output goes to `report` when given.
///
/// ```zig
/// var forward = try remote.establish(io, gpa, environ, .{ .destination = "dev@build-box" }, null);
/// defer forward.stop(io);
/// ```
pub fn establish(io: std.Io, gpa: std.mem.Allocator, environ: std.process.Environ, machine: RemoteMachine, report: ?*std.Io.Writer) !Forward {
    try core.ssh_destination.validate(machine.destination);
    const discovery = try discover(io, gpa, environ, machine.destination, report);

    // The forwarded socket lives in telar's managed, owner-only directory.
    const connector = try RuntimeConnector.init(io, environ, null);
    try connector.prepareServerDirectory();
    const local_directory = std.fs.path.dirname(connector.endpointPath()) orelse return error.InvalidRuntimeDirectory;

    var forward: Forward = .{ .child = undefined, .discovery = discovery };
    const local_path = try std.fmt.bufPrint(forward.local_path[0..std.fs.max_path_bytes], "{s}/remote-{x}-{d}.sock", .{
        local_directory,
        core.ssh_destination.hash(machine.destination),
        machine.window_slot,
    });
    forward.local_path_len = local_path.len;
    std.Io.Dir.deleteFileAbsolute(io, local_path) catch {};

    var forward_spec_buffer: [2 * std.fs.max_path_bytes + 1]u8 = undefined;
    const forward_spec = try std.fmt.bufPrint(&forward_spec_buffer, "{s}:{s}", .{ local_path, forward.discovery.endpoint() });
    // The remote side reads a pipe only this process holds. If this process
    // dies without stopping the forward, the pipe closes, `cat` ends, and
    // ssh exits with it instead of outliving the window.
    forward.child = try std.process.spawn(io, .{
        .argv = &(.{ "ssh", "-T" } ++ SshOptions.forward_arguments ++ .{ "-L", forward_spec, "--", machine.destination, "cat >/dev/null" }),
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    errdefer forward.child.kill(io);

    try waitForSocket(io, forward.localPath());
    return forward;
}

/// Connects to the forwarded socket with bounded retries, then performs the
/// normal schema handshake. It never starts a runtime locally.
///
/// ```zig
/// var connection = try remote.connectForwarded(io, &connector);
/// ```
pub fn connectForwarded(io: std.Io, connector: *const RuntimeConnector) !localsocket.SocketChannel {
    var attempt: usize = 0;
    while (attempt < connect_attempts) : (attempt += 1) {
        if (connector.connect()) |connection| {
            return connection;
        } else |err| {
            switch (err) {
                error.IncompatibleSchema => return err,
                else => io.sleep(.fromMilliseconds(connect_interval_ms), .awake) catch {},
            }
        }
    }

    return error.RemoteRuntimeUnavailable;
}

/// Asks the machine for its home, login shell and runtime socket over the
/// managed SSH connection, starting its runtime when none is running. It
/// never installs anything. SSH's error output goes to `report` when given,
/// and to standard error otherwise.
///
/// ```zig
/// const found = try remote.discover(io, gpa, environ, "dev@box", null);
/// ```
pub fn discover(io: std.Io, gpa: std.mem.Allocator, environ: std.process.Environ, destination: []const u8, report: ?*std.Io.Writer) !Discovery {
    const command = "/bin/sh -c 'printf \"%s\\n\" \"$HOME\" \"${SHELL:-/bin/sh}\"; exec telar server endpoint'";
    const options = try SshOptions.prepare(io, environ, destination);
    const managed = options.arguments();
    const result = std.process.run(gpa, io, .{
        .argv = &(.{ "ssh", "-T" } ++ managed ++ .{ "--", destination, command }),
        .stdout_limit = .limited(Discovery.max_output_bytes),
        .stderr_limit = .limited(16 * 1024),
        .timeout = endpoint_timeout,
    }) catch return error.RemoteEndpointUnavailable;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        if (report) |writer| {
            writer.writeAll(result.stderr) catch {};
        } else {
            std.debug.print("telar: `ssh {s} telar server endpoint` failed:\n{s}", .{ destination, result.stderr });
        }

        return error.RemoteEndpointUnavailable;
    }

    return Discovery.parse(result.stdout);
}

/// Asks the machine which wire schema its `telar` speaks, over the managed
/// SSH connection, so a check can tell an outdated machine from an
/// unreachable one before any window tries to attach.
///
/// ```zig
/// const schema = try remote.schema(io, gpa, environ, "dev@box");
/// ```
pub fn schema(io: std.Io, gpa: std.mem.Allocator, environ: std.process.Environ, destination: []const u8) !core.SchemaId {
    const options = try SshOptions.prepare(io, environ, destination);
    const managed = options.arguments();
    const result = std.process.run(gpa, io, .{
        .argv = &(.{ "ssh", "-T" } ++ managed ++ .{ "--", destination, "telar api schema --json" }),
        .stdout_limit = .limited(schema_output_limit),
        .stderr_limit = .limited(16 * 1024),
        .timeout = endpoint_timeout,
    }) catch return error.RemoteSchemaUnavailable;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        return error.RemoteSchemaUnavailable;
    }

    const Reported = struct { schema_version: []const u8, fingerprint: []const u8 };
    const parsed = std.json.parseFromSlice(Reported, gpa, result.stdout, .{
        .ignore_unknown_fields = true,
    }) catch return error.RemoteSchemaUnavailable;
    defer parsed.deinit();

    var id: core.SchemaId = undefined;
    const version = parsed.value.schema_version;
    const fingerprint = parsed.value.fingerprint;
    if (version.len + fingerprint.len != id.len) {
        return error.RemoteSchemaUnavailable;
    }

    @memcpy(id[0..version.len], version);
    @memcpy(id[version.len..], fingerprint);
    return id;
}

fn waitForSocket(io: std.Io, path: []const u8) !void {
    var attempt: usize = 0;
    while (attempt < connect_attempts) : (attempt += 1) {
        if (std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false })) |_| {
            return;
        } else |_| {
            io.sleep(.fromMilliseconds(connect_interval_ms), .awake) catch {};
        }
    }

    return error.RemoteForwardUnavailable;
}

test {
    _ = remote_discovery;
}
