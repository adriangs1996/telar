const Discovery = @This();
const std = @import("std");
const LaunchDefaults = @import("LaunchDefaults.zig");
pub const max_output_bytes = 3 * (std.fs.max_path_bytes + 1);

storage: [3 * std.fs.max_path_bytes]u8 = undefined,
lengths: [3]usize,

/// Copies exactly three absolute paths: home, shell and runtime socket.
/// Example: `const found = try Discovery.parse("/home/dev\n/bin/bash\n/run/user/1000/telar/runtime.sock\n");`.
pub fn parse(output: []const u8) !Discovery {
    if (output.len > max_output_bytes) {
        return error.RemoteEndpointUnavailable;
    }

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, output, "\n"), '\n');
    var result: Discovery = .{ .lengths = undefined };
    var offset: usize = 0;
    for (&result.lengths, 0..) |*length, index| {
        const path = lines.next() orelse return error.RemoteEndpointUnavailable;
        if (path.len == 0 or path.len > std.fs.max_path_bytes or path[0] != '/') {
            return error.RemoteEndpointUnavailable;
        }

        for (path) |byte| {
            if (byte < 0x20 or byte == 0x7f or (index == 2 and byte == ':')) {
                return error.RemoteEndpointUnavailable;
            }
        }

        @memcpy(result.storage[offset..][0..path.len], path);
        length.* = path.len;
        offset += path.len;
    }

    if (lines.next() != null) {
        return error.RemoteEndpointUnavailable;
    }

    return result;
}

/// Borrows launch defaults for the lifetime of this discovery result.
/// Example: `const defaults = found.launchDefaults();`.
pub fn launchDefaults(found: *const Discovery) LaunchDefaults {
    return .{ .cwd = found.storage[0..found.lengths[0]], .shell = found.storage[found.lengths[0]..][0..found.lengths[1]] };
}

/// Borrows the socket path used by the SSH forward.
/// Example: `const socket = found.endpoint();`.
pub fn endpoint(found: *const Discovery) []const u8 {
    return found.storage[found.lengths[0] + found.lengths[1] ..][0..found.lengths[2]];
}
