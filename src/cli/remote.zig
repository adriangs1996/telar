//! `telar --remote <destination>`: attach the local client to the runtime on
//! an SSH host by forwarding its Unix socket to a private local one. The
//! wire protocol, framing and backpressure are unchanged; the client simply
//! connects to the forwarded socket, and shared-memory graphics are disabled
//! because the runtime lives on another machine.

const std = @import("std");
const Forward = @import("Forward.zig");
const RuntimeConnector = @import("RuntimeConnector.zig");
const SocketChannelType = @import("telar-core").SocketChannel;
const Discovery = @import("Discovery.zig");
const remote_discovery = @import("remote_discovery.zig");

pub const connect_attempts = 100;
pub const connect_interval_ms = 100;

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
    try validateDestination(destination);
    const discovery = try remoteEndpoint(init, destination);

    // The forwarded socket lives in telar's managed, owner-only directory.
    const connector = try RuntimeConnector.init(init, null);
    try connector.prepareServerDirectory();
    const local_directory = std.fs.path.dirname(connector.endpointPath()) orelse return error.InvalidRuntimeDirectory;

    var forward: Forward = .{ .child = undefined, .discovery = discovery };
    const local_path = try std.fmt.bufPrint(forward.local_path[0..std.fs.max_path_bytes], "{s}/remote-{x}.sock", .{
        local_directory,
        destinationHash(destination),
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
pub fn connectForwarded(init: std.process.Init, connector: *const RuntimeConnector) !SocketChannelType {
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

fn remoteEndpoint(init: std.process.Init, destination: []const u8) !Discovery {
    const command = "/bin/sh -c 'printf \"%s\\n\" \"$HOME\" \"${SHELL:-/bin/sh}\"; exec telar server endpoint'";
    const result = std.process.run(init.gpa, init.io, .{
        .argv = &.{ "ssh", "-T", "-o", "BatchMode=yes", "--", destination, command },
        .stdout_limit = .limited(Discovery.max_output_bytes),
        .stderr_limit = .limited(16 * 1024),
        .timeout = endpoint_timeout,
    }) catch return error.RemoteEndpointUnavailable;
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("telar --remote: `ssh {s} telar server endpoint` failed:\n{s}", .{ destination, result.stderr });
        return error.RemoteEndpointUnavailable;
    }

    return Discovery.parse(result.stdout);
}

fn validateDestination(destination: []const u8) !void {
    if (destination.len == 0 or destination[0] == '-') {
        return error.InvalidRemoteDestination;
    }

    for (destination) |byte| {
        if (byte <= 0x20 or byte == 0x7f) {
            return error.InvalidRemoteDestination;
        }
    }
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

/// Stable per-destination suffix so two remotes never share a forward file.
///
/// ```zig
/// const suffix = destinationHash("dev@build-box");
/// ```
pub fn destinationHash(destination: []const u8) u64 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(destination, &digest, .{});
    return std.mem.readInt(u64, digest[0..8], .little);
}

test "SSH destinations cannot inject options or control bytes" {
    try validateDestination("dev@box");
    try validateDestination("telar-linux-native");
    for ([_][]const u8{ "", "-oProxyCommand=bad", "host\ncommand", "host alias" }) |destination| {
        try std.testing.expectError(error.InvalidRemoteDestination, validateDestination(destination));
    }
}

test {
    _ = remote_discovery;
}

test "destination hashes are stable and distinct" {
    try std.testing.expectEqual(destinationHash("a@b"), destinationHash("a@b"));
    try std.testing.expect(destinationHash("a@b") != destinationHash("a@c"));
}
