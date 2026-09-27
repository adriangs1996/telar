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

pub const connect_attempts = 100;
pub const connect_interval_ms = 100;

/// The largest `telar api schema --json` output read back, in bytes.
const schema_output_limit = 256 * 1024;

const endpoint_timeout: std.Io.Timeout = .{
    .duration = .{ .clock = .awake, .raw = .fromSeconds(30) },
};

/// Discovers the remote home, shell and runtime socket over SSH, then starts
/// one `ssh -N -L` forward and waits until its private socket is connectable.
///
/// ```zig
/// var forward = try establish(process_init, "dev@build-box");
/// defer forward.stop(process_init.io);
/// ```
pub fn establish(init: std.process.Init, destination: []const u8) !Forward {
    try core.ssh_destination.validate(destination);
    const discovery = try discover(init, destination);

    // The forwarded socket lives in telar's managed, owner-only directory.
    const connector = try RuntimeConnector.init(init, null);
    try connector.prepareServerDirectory();
    const local_directory = std.fs.path.dirname(connector.endpointPath()) orelse return error.InvalidRuntimeDirectory;

    var forward: Forward = .{ .child = undefined, .discovery = discovery };
    const local_path = try std.fmt.bufPrint(forward.local_path[0..std.fs.max_path_bytes], "{s}/remote-{x}.sock", .{
        local_directory,
        core.ssh_destination.hash(destination),
    });
    forward.local_path_len = local_path.len;
    std.Io.Dir.deleteFileAbsolute(init.io, local_path) catch {};

    var forward_spec_buffer: [2 * std.fs.max_path_bytes + 1]u8 = undefined;
    const forward_spec = try std.fmt.bufPrint(&forward_spec_buffer, "{s}:{s}", .{ local_path, forward.discovery.endpoint() });
    forward.child = try std.process.spawn(init.io, .{
        .argv = &.{
            "ssh",
            "-N",
            "-o",
            "BatchMode=yes",
            "-o",
            "ExitOnForwardFailure=yes",
            "-o",
            "StreamLocalBindUnlink=yes",
            "-L",
            forward_spec,
            "--",
            destination,
        },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    errdefer forward.child.kill(init.io);

    try waitForSocket(init.io, forward.localPath());
    return forward;
}

/// Connects to the forwarded socket with bounded retries, then performs the
/// normal schema handshake. It never starts a runtime locally.
///
/// ```zig
/// var connection = try connectForwarded(init, &connector);
/// ```
pub fn connectForwarded(init: std.process.Init, connector: *const RuntimeConnector) !localsocket.SocketChannel {
    var attempt: usize = 0;
    while (attempt < connect_attempts) : (attempt += 1) {
        if (connector.connect()) |connection| {
            return connection;
        } else |err| {
            switch (err) {
                error.IncompatibleSchema => return err,
                else => init.io.sleep(.fromMilliseconds(connect_interval_ms), .awake) catch {},
            }
        }
    }

    return error.RemoteRuntimeUnavailable;
}

/// Asks the machine for its home, login shell and runtime socket over the
/// managed SSH connection, starting its runtime when none is running. It
/// never installs anything.
///
/// ```zig
/// const found = try remote.discover(process_init, "dev@box");
/// ```
pub fn discover(init: std.process.Init, destination: []const u8) !Discovery {
    const command = "/bin/sh -c 'printf \"%s\\n\" \"$HOME\" \"${SHELL:-/bin/sh}\"; exec telar server endpoint'";
    const options = try SshOptions.prepare(init, destination);
    const managed = options.arguments();
    const result = std.process.run(init.gpa, init.io, .{
        .argv = &(.{ "ssh", "-T" } ++ managed ++ .{ "--", destination, command }),
        .stdout_limit = .limited(Discovery.max_output_bytes),
        .stderr_limit = .limited(16 * 1024),
        .timeout = endpoint_timeout,
    }) catch return error.RemoteEndpointUnavailable;
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("telar: `ssh {s} telar server endpoint` failed:\n{s}", .{ destination, result.stderr });
        return error.RemoteEndpointUnavailable;
    }

    return Discovery.parse(result.stdout);
}

/// Asks the machine which wire schema its `telar` speaks, over the managed
/// SSH connection, so a check can tell an outdated machine from an
/// unreachable one before any window tries to attach.
///
/// ```zig
/// const schema = try remote.schema(process_init, "dev@box");
/// ```
pub fn schema(init: std.process.Init, destination: []const u8) !core.SchemaId {
    const options = try SshOptions.prepare(init, destination);
    const managed = options.arguments();
    const result = std.process.run(init.gpa, init.io, .{
        .argv = &(.{ "ssh", "-T" } ++ managed ++ .{ "--", destination, "telar api schema --json" }),
        .stdout_limit = .limited(schema_output_limit),
        .stderr_limit = .limited(16 * 1024),
        .timeout = endpoint_timeout,
    }) catch return error.RemoteSchemaUnavailable;
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        return error.RemoteSchemaUnavailable;
    }

    const Reported = struct { schema_version: []const u8, fingerprint: []const u8 };
    const parsed = std.json.parseFromSlice(Reported, init.gpa, result.stdout, .{
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
