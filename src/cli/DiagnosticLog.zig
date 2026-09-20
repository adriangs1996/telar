const std = @import("std");
const Component = @import("arguments/DiagnosticsOptions.zig").Component;
const Log = @This();
pub const max_tail_bytes = 64 * 1024;
name: []const u8,
component: Component,
pid: u32,

/// Recognizes only exact telemetry suffixes for the selected socket. Example: `const log = DiagnosticLog.parse(name, base);`
pub fn parse(name: []const u8, base: []const u8) ?Log {
    if (!std.mem.startsWith(u8, name, base) or !std.mem.endsWith(u8, name, ".log")) {
        return null;
    }

    const suffix = name[base.len..];
    const component: Component = if (std.mem.startsWith(u8, suffix, ".runtime-")) .runtime else if (std.mem.startsWith(u8, suffix, ".client-")) .client else return null;
    const prefix_len: usize = if (component == .runtime) ".runtime-".len else ".client-".len;
    if (suffix.len <= prefix_len + ".log".len) {
        return null;
    }

    const id = std.fmt.parseUnsigned(u32, suffix[prefix_len .. suffix.len - ".log".len], 10) catch return null;
    if (id == 0) {
        return null;
    }

    return .{ .name = name, .component = component, .pid = id };
}

/// Returns a tail aligned to whole starting lines. Example: `const text = DiagnosticLog.tail(bytes, 20);`
pub fn tail(bytes: []const u8, lines: u16) []const u8 {
    if (bytes.len == 0) {
        return bytes;
    }

    var index = bytes.len - @intFromBool(bytes[bytes.len - 1] == '\n');
    var found: usize = 0;
    while (index > 0) {
        index -= 1;
        if (bytes[index] == '\n') {
            found += 1;
            if (found == lines) {
                return bytes[index + 1 ..];
            }
        }
    }

    return bytes;
}

test "log names are scoped to an exact endpoint and tail preserves final newlines" {
    try std.testing.expect(parse("x.sock-other.runtime-7.log", "x.sock") == null);
    try std.testing.expect(parse("x.sock.runtime-0.log", "x.sock") == null);
    try std.testing.expectEqual(@as(u32, 7), parse("x.sock.runtime-7.log", "x.sock").?.pid);
    try std.testing.expectEqualStrings("b\nc\n", tail("a\nb\nc\n", 2));
    try std.testing.expectEqualStrings("c", tail("a\nb\nc", 1));
}
