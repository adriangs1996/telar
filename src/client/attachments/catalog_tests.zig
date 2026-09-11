const TargetType = @import("AttachmentTarget.zig");
const std = @import("std");
const CaptureType = @import("Capture.zig");
const retained = @import("retained.zig");
const types = @import("types.zig");

const target: TargetType = .{ .pane_id = @enumFromInt(1), .pane_generation = 1 };

fn capture(gpa: std.mem.Allocator, sequence: u64) !*CaptureType {
    const result = try gpa.create(CaptureType);
    errdefer gpa.destroy(result);
    result.* = .{
        .request = .{ .target = target, .sequence = sequence },
        .png = try gpa.dupe(u8, "private png"),
        .width = 1,
        .height = 1,
    };
    return result;
}

fn adopt(store: *retained.Store, sequence: u64) !void {
    const result = try capture(store.gpa, sequence);
    errdefer result.deinit(store.gpa);
    try store.adopt(result);
}

test "headless attachment dismissal retains sensitive PNG until the consumer returns it" {
    var store = retained.Store.init(std.testing.allocator);
    defer store.deinit();
    _ = store.setTarget(target);
    try adopt(&store, 1);
    const lease = try retained.retain(&store, @enumFromInt(1));
    try std.testing.expect(store.openModal(@enumFromInt(1)));
    try std.testing.expect(store.remove(@enumFromInt(1)));
    store.reapRetired();
    try std.testing.expectEqualStrings("private png", lease.png);
    try std.testing.expect(store.cleanupPending());
    try std.testing.expect(!store.hasVisibleItems());
    try std.testing.expect(!store.hasModal());

    retained.release(&store, lease);
    store.reapRetired();
    try std.testing.expectEqual(@as(usize, 0), store.retainedBytes());
    try std.testing.expect(!store.cleanupPending());
}

test "attachment eviction skips a borrowed slot and keeps the four-item bound" {
    var store = retained.Store.init(std.testing.allocator);
    defer store.deinit();
    _ = store.setTarget(target);
    try adopt(&store, 1);
    const lease = try retained.retain(&store, @enumFromInt(1));
    defer retained.release(&store, lease);
    for (2..7) |sequence| {
        try adopt(&store, sequence);
    }

    try std.testing.expectEqualStrings("private png", lease.png);
    try std.testing.expectEqual(types.max_items, store.snapshot().len);
    try std.testing.expect(store.find(@enumFromInt(1)) != null);
    try std.testing.expect(store.find(@enumFromInt(2)) == null);
}

test "attachment initialization failures retain a single owner of captured bytes" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
}

fn allocationFailure(gpa: std.mem.Allocator) !void {
    var store = retained.Store.init(gpa);
    defer store.deinit();
    try adopt(&store, 1);
}
