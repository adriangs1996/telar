const core = @import("telar-core");
const data = @import("model");
const std = @import("std");
const retained = @import("retained.zig");

const target: data.AttachmentTarget = .{ .pane_id = @enumFromInt(1), .pane_generation = 1 };

fn capture(gpa: std.mem.Allocator, sequence: u64) !*data.Capture {
    const result = try gpa.create(data.Capture);
    errdefer gpa.destroy(result);
    result.* = .{
        .request = .{ .target = target, .sequence = sequence },
        .png = try gpa.dupe(u8, "private png"),
        .width = 1,
        .height = 1,
    };
    return result;
}

fn adopt(store: *retained.Store, sequence: u64) !?core.LimitReach {
    const result = try capture(store.gpa, sequence);
    errdefer result.deinit(store.gpa);
    return store.adopt(result);
}

/// A capture of `width` by `height` pixels whose PNG holds `bytes` bytes.
fn sizedCapture(gpa: std.mem.Allocator, sequence: u64, size: [2]u32, bytes: usize) !*data.Capture {
    const result = try gpa.create(data.Capture);
    errdefer gpa.destroy(result);
    const png = try gpa.alloc(u8, bytes);
    @memset(png, 7);
    result.* = .{
        .request = .{ .target = target, .sequence = sequence },
        .png = png,
        .width = size[0],
        .height = size[1],
    };
    return result;
}

test "headless attachment dismissal retains sensitive PNG until the consumer returns it" {
    var store = retained.Store.init(std.testing.allocator);
    defer store.deinit();
    _ = store.setTarget(target);
    _ = try adopt(&store, 1);
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
    _ = try adopt(&store, 1);
    const lease = try retained.retain(&store, @enumFromInt(1));
    defer retained.release(&store, lease);
    for (2..7) |sequence| {
        _ = try adopt(&store, sequence);
    }

    try std.testing.expectEqualStrings("private png", lease.png);
    try std.testing.expectEqual(data.attachment_types.max_items, store.snapshot().len);
    try std.testing.expect(store.find(@enumFromInt(1)) != null);
    try std.testing.expect(store.find(@enumFromInt(2)) == null);
}

test "attachment initialization failures retain a single owner of captured bytes" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
}

fn allocationFailure(gpa: std.mem.Allocator) !void {
    var store = retained.Store.init(gpa);
    defer store.deinit();
    _ = try adopt(&store, 1);
}

test "a fifth preview evicts the oldest and returns the reach of max_items" {
    var store = retained.Store.init(std.testing.allocator);
    defer store.deinit();
    _ = store.setTarget(target);
    for (1..data.attachment_types.max_items + 1) |sequence| {
        try std.testing.expect(try adopt(&store, sequence) == null);
    }

    const reach = (try adopt(&store, data.attachment_types.max_items + 1)).?;
    try std.testing.expectEqualStrings("attachments.max_items", reach.limit.name);
    try std.testing.expectEqual(@as(u64, data.attachment_types.max_items), reach.limit.value);
    try std.testing.expectEqual(@as(?u64, data.attachment_types.max_items + 1), reach.requested);
    try std.testing.expect(store.find(@enumFromInt(1)) == null);
    try std.testing.expectEqual(data.attachment_types.max_items, store.snapshot().len);

    // A dismissed preview whose bytes wait for release makes room quietly.
    try std.testing.expect(store.remove(@enumFromInt(2)));
    try std.testing.expect(try adopt(&store, data.attachment_types.max_items + 2) == null);
    try std.testing.expect(store.find(@enumFromInt(2)) == null);
}

test "PNG bytes past the retained bound evict the oldest and return its reach" {
    const gpa = std.testing.allocator;
    var store = retained.Store.init(gpa);
    defer store.deinit();
    _ = store.setTarget(target);

    // The largest PNG fits alone; the next evicts it.
    const largest = data.attachment_types.max_png_bytes;
    try std.testing.expect(try store.adopt(try sizedCapture(gpa, 1, .{ 1, 1 }, largest)) == null);
    const reach = (try store.adopt(try sizedCapture(gpa, 2, .{ 1, 1 }, 1))).?;
    try std.testing.expectEqualStrings("attachments.max_retained_bytes", reach.limit.name);
    try std.testing.expectEqual(@as(?u64, largest + 1), reach.requested);
    try std.testing.expect(store.find(@enumFromInt(1)) == null);
    try std.testing.expectEqual(@as(usize, 1), store.retainedBytes());

    const oversized = try sizedCapture(gpa, 3, .{ 1, 1 }, largest + 1);
    defer oversized.deinit(gpa);
    try std.testing.expectError(error.InvalidClipboardImage, store.adopt(oversized));
}

test "an 8K capture fits the pixel bound and one pixel past it does not" {
    const gpa = std.testing.allocator;
    var store = retained.Store.init(gpa);
    defer store.deinit();
    _ = store.setTarget(target);

    // 8K UHD, then a 16:9 frame at exactly 36 Mi pixels.
    try std.testing.expect(try store.adopt(try sizedCapture(gpa, 1, .{ 7680, 4320 }, 16)) == null);
    try std.testing.expectEqual(data.attachment_types.max_pixels, 9216 * 4096);
    try std.testing.expect(try store.adopt(try sizedCapture(gpa, 2, .{ 9216, 4096 }, 16)) == null);

    const past = try sizedCapture(gpa, 3, .{ 9217, 4096 }, 16);
    defer past.deinit(gpa);
    try std.testing.expectError(error.ClipboardImageTooLarge, store.adopt(past));
}
