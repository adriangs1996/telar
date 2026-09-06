//! Bounded SSH discovery data. All launch paths belong to the remote machine.

const std = @import("std");

pub const LaunchDefaults = struct {
    cwd: []const u8,
    shell: []const u8,
};

pub const Discovery = struct {
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
};

test "remote discovery keeps remote launch defaults and spaces in paths" {
    const found = try Discovery.parse("/home/build user\n/bin/bash\n/run/user/501/telar/runtime.sock\n");
    try std.testing.expectEqualStrings("/home/build user", found.launchDefaults().cwd);
    try std.testing.expectEqualStrings("/bin/bash", found.launchDefaults().shell);
    try std.testing.expectEqualStrings("/run/user/501/telar/runtime.sock", found.endpoint());
}

test "remote discovery rejects malformed, injected and oversized paths" {
    for ([_][]const u8{
        "",                                        "relative\n/bin/sh\n/run/telar.sock",         "/home/dev\n\n/run/telar.sock",
        "/home/dev\n/bin/sh",                      "/home/dev\n/bin/sh\n/run/telar.sock\nnoise", "/home/dev\n/bin/sh\n/run/telar:22.sock",
        "/home/dev\n/bin/sh\n/run/\x00telar.sock", "/home/dev\r\n/bin/sh\n/run/telar.sock",
    }) |output| {
        try std.testing.expectError(error.RemoteEndpointUnavailable, Discovery.parse(output));
    }

    const oversized: [std.fs.max_path_bytes + 1]u8 = @splat('/');
    try std.testing.expectError(error.RemoteEndpointUnavailable, Discovery.parse(&oversized));
}
