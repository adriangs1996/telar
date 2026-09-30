const DiagnosticsOptions = @import("arguments/DiagnosticsOptions.zig");
const core = @import("telar-core");
const std = @import("std");
const Log = @This();
/// The newest bytes of a log read: the runtime rotates its log past 1 MiB,
/// so this holds all of it and `--lines 10000` of ordinary lines.
pub const max_tail_bytes = 1024 * 1024;
name: []const u8,
component: DiagnosticsOptions.Component,
pid: u32,

/// Recognizes only exact telemetry suffixes for the selected socket. Example: `const log = DiagnosticLog.parse(name, base);`
pub fn parse(name: []const u8, base: []const u8) ?Log {
    const log = core.DiagnosticLogName.parse(name) orelse return null;
    if (log.rotated or !std.mem.eql(u8, name[0..log.endpoint_len], base)) {
        return null;
    }

    const component: DiagnosticsOptions.Component = switch (log.role) {
        .runtime => .runtime,
        .client => .client,
    };
    return .{ .name = name, .component = component, .pid = log.pid };
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
