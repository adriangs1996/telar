//! Owns query entries until their bounded payload transfers into a result.

const std = @import("std");
const model = @import("model.zig");

test "result accumulation releases rejected entries and survives allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseOwnership, .{});
}

fn exerciseOwnership(gpa: std.mem.Allocator) !void {
    var accumulator: Accumulator = .{ .gpa = gpa, .limit = 1 };
    defer accumulator.deinit();
    const entry: model.Entry = .{
        .id = 1,
        .pane_id = @enumFromInt(1),
        .started_at_ms = 0,
        .duration_ns = 0,
        .exit_code = 0,
        .status = .completed,
        .author = .human,
        .command = try gpa.dupe(u8, "ls"),
        .cwd = &.{},
        .workspace_path = &.{},
    };
    try std.testing.expect(try accumulator.append(entry));
    var rejected = entry;
    rejected.command = try gpa.dupe(u8, "pwd");
    try std.testing.expect(!try accumulator.append(rejected));
    const query = try model.Query.init(.{
        .request_id = @enumFromInt(1),
        .origin = .{ .client = .{ .id = 1, .generation = 1 }, .close_after_reply = false },
    });
    const result = try accumulator.finish(&query, false);
    defer result.deinit();
    try std.testing.expect(result.has_more);
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expectEqual(@as(usize, 0), accumulator.entries.items.len);
}

pub const Accumulator = @import("Accumulator.zig");
