//! One thread-safe sequence authority shared by a session's observation producers.

const Sequence = @import("Sequence.zig");
const std = @import("std");

fn reserveBatch(sequence: *Sequence, output: *[1024]u64) void {
    for (output) |*number| {
        number.* = sequence.reserve().?;
    }
}

test "concurrent history producers reserve disjoint sequences" {
    var sequence: Sequence = .{};
    var first: [1024]u64 = undefined;
    var second: [1024]u64 = undefined;
    const thread = try std.Thread.spawn(.{}, reserveBatch, .{ &sequence, &first });
    reserveBatch(&sequence, &second);
    thread.join();
    var seen: [2049]bool = @splat(false);

    for (first ++ second) |number| {
        try std.testing.expect(number > 0 and number < seen.len);
        try std.testing.expect(!seen[number]);
        seen[number] = true;
    }
}

test "history sequence exhaustion never reuses an identity" {
    var sequence: Sequence = .{ .value = .init(std.math.maxInt(i64) - 1) };
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(i64)), sequence.reserve());
    try std.testing.expect(sequence.reserve() == null);
    try std.testing.expect(sequence.reserve() == null);
}
