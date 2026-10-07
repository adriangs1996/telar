//! Finds and reads a workspace's favicon file off the interactive path:
//! `favicon.png`, `favicon.ico`, then `.telar/icon.png` under the workspace root, regular
//! files only, at most `max_file_bytes`. Decoding belongs to the adapter.
const core = @import("telar-core");
const std = @import("std");

pub const max_file_bytes: usize = 1024 * 1024;
pub const candidates = [_][]const u8{ "favicon.png", "favicon.ico", ".telar/icon.png" };

/// Reads the first candidate that exists into `buffer`, which must hold
/// `max_file_bytes`. A larger or irregular file is skipped like a missing one.
/// Example: `const bytes = try favicon_lookup.read(io, cwd, buffer);`
pub fn read(io: std.Io, cwd: []const u8, buffer: []u8) ![]const u8 {
    std.debug.assert(buffer.len >= max_file_bytes);
    if (cwd.len == 0 or cwd.len > core.max_cwd_bytes) {
        return error.FaviconNotFound;
    }

    var path: [core.max_cwd_bytes + 32]u8 = undefined;
    for (candidates) |name| {
        const joined = std.fmt.bufPrint(&path, "{s}/{s}", .{ cwd, name }) catch continue;
        if (readRegular(io, joined, buffer[0..max_file_bytes]) catch null) |bytes| {
            return bytes;
        }
    }

    return error.FaviconNotFound;
}

fn readRegular(io: std.Io, path: []const u8, buffer: []u8) !?[]const u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size > buffer.len) {
        return null;
    }

    const len = try file.readPositionalAll(io, buffer[0..@intCast(stat.size)], 0);
    return buffer[0..len];
}
