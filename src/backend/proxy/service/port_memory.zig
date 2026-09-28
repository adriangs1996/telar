//! The port the proxy bound last time, kept in the proxy directory so the
//! next start prefers it and a child that inherited `HTTPS_PROXY` keeps its
//! destination across runtime restarts. Losing the file only costs that
//! stability.

const localca = @import("localca");
const std = @import("std");
const listener_support = @import("listener_support.zig");

const ca = localca.ca;

/// Returns the remembered port when the file holds one inside the proxy
/// range; anything else is forgotten.
///
/// ```zig
/// const preferred = port_memory.recall(io, paths.port);
/// ```
pub fn recall(io: std.Io, path: []const u8) ?u16 {
    var buffer: [16]u8 = undefined;
    const bytes = std.Io.Dir.cwd().readFile(io, path, &buffer) catch return null;
    const text = std.mem.trimEnd(u8, bytes, "\r\n");
    const port = std.fmt.parseInt(u16, text, 10) catch return null;
    if (port < listener_support.first_port or port >= listener_support.first_port + listener_support.port_attempts) {
        return null;
    }

    return port;
}

/// Records the bound port. Failure to write is not an error: the proxy
/// runs on the port it bound either way.
///
/// ```zig
/// port_memory.remember(io, paths.port, listener.port());
/// ```
pub fn remember(io: std.Io, path: []const u8, port: u16) void {
    var line: [8]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "{d}\n", .{port}) catch return;
    ca.writeSecure(io, .{ .path = path, .bytes = text, .exclusive = false }) catch {};
}

test "the remembered port survives a round trip and rejects foreign values" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buffer[0..try temp.dir.realPath(io, &directory_buffer)];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/proxy-port", .{directory});

    try std.testing.expect(recall(io, path) == null);
    remember(io, path, listener_support.first_port + 3);
    try std.testing.expectEqual(@as(?u16, listener_support.first_port + 3), recall(io, path));
    remember(io, path, listener_support.first_port + 5);
    try std.testing.expectEqual(@as(?u16, listener_support.first_port + 5), recall(io, path));

    try temp.dir.writeFile(io, .{ .sub_path = "proxy-port", .data = "80\n" });
    try std.testing.expect(recall(io, path) == null);
    try temp.dir.writeFile(io, .{ .sub_path = "proxy-port", .data = "port\n" });
    try std.testing.expect(recall(io, path) == null);
}
