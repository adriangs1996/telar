const cellgrid = @import("cellgrid");
const data = @import("model");
const std = @import("std");
const MetricsLabel = @This();

bytes: [96]u8 = undefined,
len: usize = 0,

pub fn init(values: ?data.SystemMetrics) MetricsLabel {
    var label: MetricsLabel = .{};
    const metrics = values orelse return label;
    const written = std.fmt.bufPrint(&label.bytes, " CPU {d}%  MEM {d}.{d}G", .{ metrics.cpu_percent, metrics.memory_used_decigib / 10, metrics.memory_used_decigib % 10 }) catch unreachable;
    label.len = written.len;
    if (metrics.battery_percent) |battery| {
        const tail = std.fmt.bufPrint(label.bytes[label.len..], "  BAT {d}%", .{battery}) catch unreachable;
        label.len += tail.len;
    }

    return label;
}

pub fn text(self: *const MetricsLabel) []const u8 {
    return self.bytes[0..self.len];
}

pub fn width(self: *const MetricsLabel) u16 {
    return cellgrid.text.measure(self.text());
}
