const std = @import("std");
const Histogram = @This();

pub const bucket_count = 64;
buckets: [bucket_count]u64 = @splat(0),
count: u64 = 0,
total_ns: u64 = 0,
max_ns: u64 = 0,
overflow: bool = false,

/// Bucket zero covers 0..1 ns; bucket k covers 2^(k-1)+1..2^k ns.
/// The last bucket includes larger values. Example: `histogram.observe(350);`
pub fn observe(self: *Histogram, ns: u64) void {
    const index: usize = if (ns <= 1) 0 else @min(bucket_count - 1, 64 - @clz(ns - 1));
    const sum = @addWithOverflow(self.total_ns, ns);
    self.overflow = self.overflow or sum[1] != 0 or self.count == std.math.maxInt(u64) or self.buckets[index] == std.math.maxInt(u64);
    self.total_ns +|= ns;
    self.count +|= 1;
    self.buckets[index] +|= 1;
    self.max_ns = @max(self.max_ns, ns);
}

test "profile histograms retain boundaries and signal saturation" {
    var histogram: Histogram = .{};
    for ([_]u64{ 0, 1, 2, 3, 4, 5, 8, 9 }) |ns| {
        histogram.observe(ns);
    }
    try std.testing.expectEqualSlices(u64, &.{ 2, 1, 2, 2, 1 }, histogram.buckets[0..5]);
    try std.testing.expectEqual(@as(u64, 8), histogram.count);
    histogram.total_ns = std.math.maxInt(u64);
    histogram.observe(1);
    try std.testing.expect(histogram.overflow);
}
