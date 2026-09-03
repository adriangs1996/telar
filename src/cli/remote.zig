//! `telar --remote <destination>`: attach the local client to the runtime on
//! an SSH host by forwarding its Unix socket to a private local one. The
//! wire protocol, framing and backpressure are unchanged; the client simply
//! connects to the forwarded socket, and shared-memory graphics are disabled
//! because the runtime lives on another machine.

const std = @import("std");
const core = @import("telar-core");
const frontend = @import("telar-frontend");
const runtime_connection = @import("runtime_connection.zig");

const Io = std.Io;
const RuntimeConnector = runtime_connection.RuntimeConnector;

pub const connect_attempts = 100;
pub const connect_interval_ms = 100;

const endpoint_timeout: Io.Timeout = .{
    .duration = .{ .clock = .awake, .raw = .fromSeconds(30) },
};

/// One live SSH socket forward. Stopping it kills the ssh child and removes
/// the local socket file.
pub const Forward = struct {
    child: std.process.Child,
    local_path: [std.fs.max_path_bytes:0]u8 = undefined,
    local_path_len: usize = 0,

    pub fn localPath(forward: *const Forward) []const u8 {
        return forward.local_path[0..forward.local_path_len];
    }

    pub fn localPathZ(forward: *Forward) [*:0]const u8 {
        forward.local_path[forward.local_path_len] = 0;
        return forward.local_path[0..forward.local_path_len :0];
    }

    pub fn stop(forward: *Forward, io: Io) void {
        forward.child.kill(io);
        Io.Dir.deleteFileAbsolute(io, forward.localPath()) catch {};
    }
};

/// Discovers the remote runtime's socket over SSH, starts one `ssh -N -L`
/// forward to a private local socket and waits until it is connectable.
///
/// ```zig
/// var forward = try establish(process_init, "dev@build-box");
/// defer forward.stop(process_init.io);
/// ```
pub fn establish(init: std.process.Init, destination: []const u8) !Forward {
    var remote_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const remote_path = try remoteEndpoint(init, destination, &remote_buffer);

    // The forwarded socket lives in telar's managed, owner-only directory.
    const connector = try RuntimeConnector.init(init, null);
    try connector.prepareServerDirectory();
    const local_directory = std.fs.path.dirname(connector.endpointPath()) orelse return error.InvalidRuntimeDirectory;

    var forward: Forward = .{ .child = undefined };
    const local_path = try std.fmt.bufPrint(forward.local_path[0..std.fs.max_path_bytes], "{s}/remote-{x}.sock", .{
        local_directory,
        destinationHash(destination),
    });
    forward.local_path_len = local_path.len;
    Io.Dir.deleteFileAbsolute(init.io, local_path) catch {};

    var forward_spec_buffer: [2 * std.fs.max_path_bytes + 1]u8 = undefined;
    const forward_spec = try std.fmt.bufPrint(&forward_spec_buffer, "{s}:{s}", .{ local_path, remote_path });
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
pub fn connectForwarded(init: std.process.Init, connector: *const RuntimeConnector) !core.transport.SocketChannel {
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

fn remoteEndpoint(init: std.process.Init, destination: []const u8, buffer: []u8) ![]const u8 {
    const result = std.process.run(init.gpa, init.io, .{
        .argv = &.{ "ssh", "-o", "BatchMode=yes", destination, "telar", "server", "endpoint" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(16 * 1024),
        .timeout = endpoint_timeout,
    }) catch return error.RemoteEndpointUnavailable;
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("telar --remote: `ssh {s} telar server endpoint` failed:\n{s}", .{ destination, result.stderr });
        return error.RemoteEndpointUnavailable;
    }

    const path = std.mem.trim(u8, result.stdout, " \r\n");
    if (path.len == 0 or path.len > buffer.len or !std.fs.path.isAbsolute(path) or
        std.mem.indexOfScalar(u8, path, '\n') != null)
    {
        return error.RemoteEndpointUnavailable;
    }

    @memcpy(buffer[0..path.len], path);
    return buffer[0..path.len];
}

fn waitForSocket(io: Io, path: []const u8) !void {
    var attempt: usize = 0;
    while (attempt < connect_attempts) : (attempt += 1) {
        if (Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false })) |_| {
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

test "destination hashes are stable and distinct" {
    try std.testing.expectEqual(destinationHash("a@b"), destinationHash("a@b"));
    try std.testing.expect(destinationHash("a@b") != destinationHash("a@c"));
}
