const std = @import("std");
const profiling = @import("profiling.zig");
const Histogram = @import("ProfileHistogram.zig");
const Counters = @This();

thread: u64 align(std.atomic.cache_line) = 0,
values: [std.enums.values(profiling.Metric).len]u64 = @splat(0),
histograms: [std.enums.values(profiling.Phase).len]Histogram = @splat(.{}),
overflow: bool = false,

/// This bank has exactly one writer. Example: `counts.add(.gui_draw, 1);`
pub fn add(self: *Counters, metric: profiling.Metric, amount: u64) void {
    const value = &self.values[@intFromEnum(metric)];
    const sum = @addWithOverflow(value.*, amount);
    self.overflow = self.overflow or sum[1] != 0;
    value.* +|= amount;
}

/// Writes a stable bank or owner-thread snapshot. Example: `try counts.write(writer);`
pub fn write(self: *const Counters, writer: *std.Io.Writer) !void {
    for (std.enums.values(profiling.Metric), self.values) |metric, value| {
        try writer.print("{{\"type\":\"count\",\"thread\":{d},\"metric\":\"{s}\",\"value\":{d},\"unit\":\"{s}\",\"source\":\"{s}\",\"coverage\":\"{s}\",\"overflow\":{}}}\n", .{ self.thread, @tagName(metric), value, profiling.unit(metric), profiling.source(metric), profiling.coverage(metric), self.overflow });
    }
    for (std.enums.values(profiling.Phase), self.histograms) |phase, histogram| {
        try writer.print("{{\"type\":\"histogram\",\"thread\":{d},\"phase\":\"{s}\",\"count\":{d},\"total_ns\":{d},\"max_ns\":{d},\"overflow\":{},\"buckets\":[", .{ self.thread, @tagName(phase), histogram.count, histogram.total_ns, histogram.max_ns, histogram.overflow });
        for (histogram.buckets, 0..) |bucket, index| {
            if (index != 0) {
                try writer.writeByte(',');
            }
            try writer.print("{d}", .{bucket});
        }
        try writer.writeAll("]}\n");
    }
}

test "profile counters saturate without wrapping and copies are independent" {
    var counts: Counters = .{};
    counts.add(.gui_draw, 4);
    const snapshot = counts;
    counts.add(.gui_draw, std.math.maxInt(u64));
    try std.testing.expect(counts.overflow);
    try std.testing.expectEqual(std.math.maxInt(u64), counts.values[@intFromEnum(profiling.Metric.gui_draw)]);
    try std.testing.expectEqual(@as(u64, 4), snapshot.values[@intFromEnum(profiling.Metric.gui_draw)]);
}
