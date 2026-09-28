const core = @import("telar-core");
const std = @import("std");
const LaunchDefaults = @import("LaunchDefaults.zig");
/// What a remote machine reports before a client attaches: its home, login
/// shell and runtime socket, and the wire schema its `telar` speaks.
const Discovery = @This();

/// Three paths and the schema, each on its own line.
pub const max_output_bytes = 3 * (std.fs.max_path_bytes + 1) + schema_line_bytes;

const schema_line_bytes = @sizeOf(core.SchemaId) + 1;

storage: [3 * std.fs.max_path_bytes]u8 = undefined,
lengths: [3]usize,
schema: core.SchemaId,

/// Copies exactly three absolute paths, home, shell and runtime socket,
/// then the schema id. A `telar` that prints anything else, such as one
/// from before the schema line or a shell startup file that prints, is
/// refused, since retrying would read the same.
/// Example: `const found = try Discovery.parse("/home/dev\n/bin/bash\n/run/user/1000/telar/runtime.sock\nv12cd733\n");`.
pub fn parse(output: []const u8) !Discovery {
    if (output.len > max_output_bytes) {
        return error.RemoteDiscoveryUnreadable;
    }

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, output, "\n"), '\n');
    var result: Discovery = .{ .lengths = undefined, .schema = undefined };
    var offset: usize = 0;
    for (&result.lengths, 0..) |*length, index| {
        const path = lines.next() orelse return error.RemoteDiscoveryUnreadable;
        if (path.len == 0 or path.len > std.fs.max_path_bytes or path[0] != '/') {
            return error.RemoteDiscoveryUnreadable;
        }

        for (path) |byte| {
            if (byte < 0x20 or byte == 0x7f or (index == 2 and byte == ':')) {
                return error.RemoteDiscoveryUnreadable;
            }
        }

        @memcpy(result.storage[offset..][0..path.len], path);
        length.* = path.len;
        offset += path.len;
    }

    const schema = lines.next() orelse return error.RemoteDiscoveryUnreadable;
    if (schema.len != result.schema.len) {
        return error.RemoteDiscoveryUnreadable;
    }

    for (schema) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) {
            return error.RemoteDiscoveryUnreadable;
        }
    }

    @memcpy(&result.schema, schema);
    if (lines.next() != null) {
        return error.RemoteDiscoveryUnreadable;
    }

    return result;
}

/// Borrows launch defaults for the lifetime of this discovery result.
/// Example: `const defaults = found.launchDefaults();`.
pub fn launchDefaults(self: *const Discovery) LaunchDefaults {
    return .{ .cwd = self.storage[0..self.lengths[0]], .shell = self.storage[self.lengths[0]..][0..self.lengths[1]] };
}

/// Borrows the remote runtime's socket path.
/// Example: `const socket = found.endpoint();`.
pub fn endpoint(self: *const Discovery) []const u8 {
    return self.storage[self.lengths[0] + self.lengths[1] ..][0..self.lengths[2]];
}

/// Whether the machine's `telar` speaks this build's wire schema.
/// Example: `if (!found.compatible()) return error.RemoteTelarIncompatible;`.
pub fn compatible(self: *const Discovery) bool {
    return std.mem.eql(u8, &self.schema, &core.schema_id);
}
