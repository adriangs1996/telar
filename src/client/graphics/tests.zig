const PaneIdType = @import("telar-core").PaneId;
const ImageType = @import("telar-core").Image;
const retained = @import("retained.zig");
const std = @import("std");
const store_module = @import("store.zig");
const ShmNameType = @import("telar-core").ShmName;

const pane_id: PaneIdType = @enumFromInt(1);
const image: ImageType = .{ .key = .{ .image_id = 1, .generation = 1 }, .format = .rgb, .width = 1, .height = 1, .byte_len = 3 };

fn receive(store: *retained.Store, metadata: ImageType) !void {
    try store.applyImage(.{ .pane_id = pane_id, .revision = metadata.key.generation, .image = metadata });
    try store.applyChunk(.{ .pane_id = pane_id, .revision = metadata.key.generation, .key = metadata.key, .offset = 0, .bytes = "rgb" });
}

test "headless catalog holds replaced pixels and credit until the final consumer releases" {
    var store = retained.Store.init(std.testing.allocator);
    defer store.deinit();
    try receive(&store, image);
    const lease = try retained.retain(&store, store_module.identity(pane_id, image.key));
    var next = image;
    next.key.generation += 1;
    try receive(&store, next);
    try std.testing.expectEqualStrings("rgb", lease.pixels);
    try std.testing.expectEqual(@as(usize, 6), store.total_bytes);
    try std.testing.expect(store.peekCredit() == null);

    retained.release(&store, lease);
    try std.testing.expectEqual(@as(usize, 3), store.total_bytes);
    const credit = store.peekCredit().?;
    try std.testing.expectEqual(@as(usize, 3), credit.bytes);
    store.consumeCredit(credit);
    try std.testing.expect(store.peekCredit() == null);
}

test "snapshot retirement cannot free pixels borrowed by asynchronous presentation" {
    var store = retained.Store.init(std.testing.allocator);
    defer store.deinit();
    try receive(&store, image);
    const lease = try retained.retain(&store, store_module.identity(pane_id, image.key));
    try store.applySnapshot(.{ .pane_id = pane_id, .revision = 2, .phase = .begin });
    try std.testing.expectEqualStrings("rgb", lease.pixels);
    try std.testing.expect(store.peekCredit() == null);
    try std.testing.expectError(error.GraphicsResyncRequired, store.applyImage(.{ .pane_id = pane_id, .revision = 2, .image = image }));
    retained.release(&store, lease);
    try std.testing.expectEqual(@as(usize, 0), store.total_bytes);
    try std.testing.expectEqual(@as(usize, 3), store.peekCredit().?.bytes);
}

test "detached generations never return their credit to a later attachment" {
    var store = retained.Store.init(std.testing.allocator);
    defer store.deinit();
    try receive(&store, image);
    const lease = try retained.retain(&store, store_module.identity(pane_id, image.key));
    store.clearPane(pane_id);
    try std.testing.expectEqualStrings("rgb", lease.pixels);
    try std.testing.expectEqual(@as(usize, 3), store.total_bytes);
    try store.applySnapshot(.{ .pane_id = pane_id, .revision = 2, .phase = .begin });
    retained.release(&store, lease);
    try std.testing.expectEqual(@as(usize, 0), store.total_bytes);
    try std.testing.expect(store.peekCredit() == null);
}

test "rejected shared transfers relinquish their unique name without freeing a borrowed generation" {
    if (!store_module.supportsSharedMemory()) {
        return error.SkipZigTest;
    }

    var source = retained.Store.initSharedMemory(std.testing.allocator);
    defer source.deinit();
    try receive(&source, image);
    const shared = source.images.get(store_module.identity(pane_id, image.key)).?.shared orelse return error.SharedMemoryUnavailable;
    const name = try ShmNameType.init(shared.slice());
    var store = retained.Store.init(std.testing.allocator);
    defer store.deinit();
    try receive(&store, image);
    const lease = try retained.retain(&store, store_module.identity(pane_id, image.key));
    defer retained.release(&store, lease);

    try std.testing.expectError(error.GraphicsResyncRequired, store.applySharedImage(.{
        .pane_id = pane_id,
        .revision = 2,
        .image = image,
        .name = name,
    }));
    try std.testing.expectEqualStrings("rgb", lease.pixels);
    const fd = std.c.shm_open(name.sliceZ(), @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })), @as(u16, 0));
    if (fd >= 0) {
        _ = std.c.close(fd);
        return error.SharedNameNotReleased;
    }
}

test "image receive rollback releases every allocation without a terminal delivery store" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
}

fn allocationFailure(gpa: std.mem.Allocator) !void {
    var store = retained.Store.init(gpa);
    defer store.deinit();
    try receive(&store, image);
    var next = image;
    next.key.generation += 1;
    try receive(&store, next);
}
