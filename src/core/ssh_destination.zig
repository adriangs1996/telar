//! An SSH destination as telar hands it to `ssh`: a host alias or
//! `user@host`, never an option, whitespace or a control byte.
const std = @import("std");

/// The longest destination a machine profile stores, in bytes.
pub const max_bytes = 255;

/// Refuses a destination `ssh` could read as an option or split into words.
///
/// ```zig
/// try ssh_destination.validate("dev@build-box");
/// ```
pub fn validate(destination: []const u8) !void {
    if (destination.len == 0 or destination[0] == '-') {
        return error.InvalidRemoteDestination;
    }

    for (destination) |byte| {
        if (byte <= ' ' or byte == std.ascii.control_code.del) {
            return error.InvalidRemoteDestination;
        }
    }
}

/// A stable digest of the destination, so files named after one never
/// collide with another's.
///
/// ```zig
/// const suffix = ssh_destination.hash("dev@build-box");
/// ```
pub fn hash(destination: []const u8) u64 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(destination, &digest, .{});
    return std.mem.readInt(u64, digest[0..@sizeOf(u64)], .little);
}

test "SSH destinations cannot inject options or control bytes" {
    try validate("dev@box");
    try validate("telar-linux-native");

    for ([_][]const u8{ "", "-oProxyCommand=bad", "host\ncommand", "host alias", "host\x7f" }) |destination| {
        try std.testing.expectError(error.InvalidRemoteDestination, validate(destination));
    }
}

test "destination hashes are stable and distinct" {
    try std.testing.expectEqual(hash("a@b"), hash("a@b"));
    try std.testing.expect(hash("a@b") != hash("a@c"));
}
