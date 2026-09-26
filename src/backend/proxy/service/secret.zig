//! The proxy secret on disk: one hex line in the owner-only proxy directory,
//! created on first use and read on every start, so a child that inherited
//! `HTTPS_PROXY` keeps working across runtime restarts. Deleting the file
//! rotates the secret.

const localca = @import("localca");
const std = @import("std");
const identity = @import("../identity.zig");

const ca = localca.ca;
const hex_bytes = identity.secret_bytes * 2;

/// Reads the secret at `path`, creating a fresh random one when the file is
/// missing. A file with any other content is a corrupt secret.
///
/// ```zig
/// var secret = try secret.ensure(io, paths.secret);
/// defer std.crypto.secureZero(u8, &secret);
/// ```
pub fn ensure(io: std.Io, path: []const u8) !identity.Secret {
    if (try load(io, path)) |existing| {
        return existing;
    }

    var fresh = identity.randomSecret(io);
    defer std.crypto.secureZero(u8, &fresh);
    var line: [hex_bytes + 1]u8 = undefined;
    defer std.crypto.secureZero(u8, &line);
    _ = try std.fmt.bufPrint(&line, "{x}\n", .{fresh});
    try ca.writeSecure(io, .{ .path = path, .bytes = &line, .exclusive = true });
    return fresh;
}

/// Reads the secret at `path`, or null when no file exists yet.
///
/// ```zig
/// const existing = try secret.load(io, paths.secret);
/// ```
pub fn load(io: std.Io, path: []const u8) !?identity.Secret {
    var buffer: [hex_bytes + 8]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    const bytes = std.Io.Dir.cwd().readFile(io, path, &buffer) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return error.ProxySecretCorrupt,
    };
    const text = std.mem.trimEnd(u8, bytes, "\r\n");
    if (text.len != hex_bytes) {
        return error.ProxySecretCorrupt;
    }

    var loaded: identity.Secret = undefined;
    defer std.crypto.secureZero(u8, &loaded);
    _ = std.fmt.hexToBytes(&loaded, text) catch return error.ProxySecretCorrupt;
    return loaded;
}

test "the proxy secret is created once and reread unchanged" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buffer[0..try temp.dir.realPath(io, &directory_buffer)];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/proxy-secret", .{directory});

    try std.testing.expect(try load(io, path) == null);
    const first = try ensure(io, path);
    const second = try ensure(io, path);
    try std.testing.expect(identity.sameSecret(&first, &second));
    try std.testing.expect(identity.sameSecret(&first, &(try load(io, path)).?));

    try temp.dir.writeFile(io, .{ .sub_path = "proxy-secret", .data = "not hex\n" });
    try std.testing.expectError(error.ProxySecretCorrupt, load(io, path));
}
