//! Synchronization of one pane's graphics state across client attachments.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../../../attachment/root.zig");
const media_mod = @import("../../../../media/root.zig");
const pane_mod = @import("../../../../pane/root.zig");
const test_support = @import("../../../tests/support.zig");

const AttachmentStore = attachment_mod.AttachmentStore;
const Pane = pane_mod.Pane;
const shared_memory_supported = pane_mod.shared_transfer.shared_memory_supported;

pub const Stats = struct {
    staged: u64 = 0,
};

/// Invalidates reset projections first, then freezes at most one transfer per
/// client while the pane's media storage is idle. A failed freeze abandons
/// only that disposable client projection.
///
/// ```zig
/// const stats = synchronize(pane, attachment_stores, media_reset);
/// ```
pub fn synchronize(pane: *Pane, stores: []const *AttachmentStore, media_reset: bool) Stats {
    if (media_reset) {
        for (stores) |store| {
            _ = store.requestGraphicsSnapshot(pane.id);
        }
    }

    var stats: Stats = .{};
    for (stores) |store| {
        const attachment = store.find(pane.id) orelse continue;

        if (attachment.hasFrozenGraphics() or attachment.graphicsCaughtUp()) {
            continue;
        }

        const staged = attachment.stageGraphics(store.availableGraphicsCredit()) catch {
            attachment.abandonGraphics();
            continue;
        };
        if (staged == .staged) {
            stats.staged +|= 1;
        }
    }
    discardUnwanted(pane, stores);

    return stats;
}

/// Releases generations the media actor parked that no shared-transport
/// client can still adopt: each such client either knows the image already
/// or holds that very generation frozen. Keeping them would pin pane quota
/// until the next generation replaced them.
fn discardUnwanted(pane: *Pane, stores: []const *AttachmentStore) void {
    for (pane.prepared_transfers.items) |slot| {
        const parked = slot orelse continue;
        if (wanted(parked.metadata.key, pane.id, stores)) {
            continue;
        }
        pane.prepared_transfers.discard(parked.metadata.key, &pane.media_allocator);
    }
}

fn wanted(key: core.graphics.ImageKey, pane_id: core.schema.PaneId, stores: []const *AttachmentStore) bool {
    for (stores) |store| {
        const attachment = store.find(pane_id) orelse continue;
        if (!attachment.graphics.shared_transport) {
            continue;
        }
        if (attachment_mod.knowsImage(attachment, key)) {
            continue;
        }
        if (attachment.graphics.transfer) |transfer| {
            if (std.meta.eql(transfer.metadata.key, key)) {
                continue;
            }
        }
        return true;
    }
    return false;
}

fn objectExists(name: core.graphics.ShmName) bool {
    const fd = std.c.shm_open(name.sliceZ(), @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })), @as(u16, 0));
    if (std.posix.errno(fd) != .SUCCESS) {
        return false;
    }
    _ = std.c.close(fd);
    return true;
}

fn liveKey(fixture: *test_support.PaneFixture, image_id: u32) core.graphics.ImageKey {
    const image = fixture.pane.media.terminal.screens.active.kitty_images.imageById(image_id).?;
    return .{ .image_id = image.id, .generation = image.generation };
}

test "shared transport clients are counted on the pane for the media actor" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    try std.testing.expectEqual(@as(u8, 0), fixture.pane.shared_transport_clients.load(.acquire));
    _ = fixture.attachments.configureGraphics(true);
    try std.testing.expectEqual(@as(u8, 1), fixture.pane.shared_transport_clients.load(.acquire));
    _ = fixture.attachments.configureGraphics(true);
    try std.testing.expectEqual(@as(u8, 1), fixture.pane.shared_transport_clients.load(.acquire));
    _ = fixture.attachments.configureGraphics(false);
    try std.testing.expectEqual(@as(u8, 0), fixture.pane.shared_transport_clients.load(.acquire));
}

test "a generation the media actor froze is adopted without a runtime-thread copy" {
    if (comptime !shared_memory_supported) {
        return error.SkipZigTest;
    }
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    _ = fixture.attachments.configureGraphics(true);
    try fixture.addRgbaImage(7);
    const key = liveKey(&fixture, 7);

    var stats: media_mod.Stats = .{};
    fixture.pane.prepareSharedTransfers(&stats);

    try std.testing.expectEqual(@as(u64, 1), stats.prepared_frames);
    try std.testing.expect(fixture.pane.prepared_transfers.holds(key));
    const used_before = fixture.pane.media_allocator.used;
    fixture.pane.refreshGraphicsProjection();
    const stores = [_]*AttachmentStore{&fixture.attachments};

    const projection = synchronize(fixture.pane, &stores, false);

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    try std.testing.expectEqual(@as(u64, 1), projection.staged);
    try std.testing.expect(attachment.hasFrozenGraphics());
    const transfer = attachment.graphics.transfer.?;
    try std.testing.expect(transfer.shared_name != null);
    try std.testing.expect(objectExists(transfer.shared_name.?));
    try std.testing.expectEqual(@as(u32, 1), attachment.graphics.adopted);
    try std.testing.expectEqual(@as(u64, 0), attachment.graphics.freeze.count);
    try std.testing.expect(!fixture.pane.prepared_transfers.holds(key));
    // The actor's reservation moved to the transfer instead of doubling.
    try std.testing.expectEqual(used_before, fixture.pane.media_allocator.used);

    // A second batch offers nothing for a generation already handed out.
    var again: media_mod.Stats = .{};
    fixture.pane.prepareSharedTransfers(&again);
    try std.testing.expectEqual(@as(u64, 0), again.prepared_frames);
}

test "a replaced generation releases the object the actor parked for it" {
    if (comptime !shared_memory_supported) {
        return error.SkipZigTest;
    }
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    _ = fixture.attachments.configureGraphics(true);
    try fixture.addRgbaImage(7);
    var first: media_mod.Stats = .{};
    fixture.pane.prepareSharedTransfers(&first);
    const first_key = liveKey(&fixture, 7);
    const first_name = fixture.pane.prepared_transfers.take(first_key).?.name;
    try std.testing.expect(fixture.pane.prepared_transfers.put(.{
        .metadata = .{ .key = first_key, .format = .rgba, .width = 1, .height = 1, .byte_len = 4 },
        .name = first_name,
        .reserved_len = 4,
    }, &fixture.pane.media_allocator));
    const used_before = fixture.pane.media_allocator.used;

    try fixture.addRgbaImage(7);
    var second: media_mod.Stats = .{};
    fixture.pane.prepareSharedTransfers(&second);

    const second_key = liveKey(&fixture, 7);
    try std.testing.expect(second_key.generation != first_key.generation);
    try std.testing.expectEqual(@as(u64, 1), second.prepared_frames);
    try std.testing.expect(!objectExists(first_name));
    try std.testing.expect(!fixture.pane.prepared_transfers.holds(first_key));
    try std.testing.expect(fixture.pane.prepared_transfers.holds(second_key));
    try std.testing.expectEqual(used_before, fixture.pane.media_allocator.used);
}

test "parked generations every client already knows are released at synchronization" {
    if (comptime !shared_memory_supported) {
        return error.SkipZigTest;
    }
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    _ = fixture.attachments.configureGraphics(true);
    try fixture.addRgbaImage(7);
    const key = liveKey(&fixture, 7);
    const attachment = fixture.attachments.find(fixture.pane.id).?;
    try attachment_mod.rememberImage(attachment, key);
    fixture.pane.refreshGraphicsProjection();
    attachment.graphics.observed_revision = fixture.pane.graphics_revision;
    const used_before = fixture.pane.media_allocator.used;
    var stats: media_mod.Stats = .{};
    fixture.pane.prepareSharedTransfers(&stats);
    const parked_name = fixture.pane.prepared_transfers.items[0].?.name;
    const stores = [_]*AttachmentStore{&fixture.attachments};

    const projection = synchronize(fixture.pane, &stores, false);

    try std.testing.expectEqual(@as(u64, 0), projection.staged);
    try std.testing.expect(!attachment.hasFrozenGraphics());
    try std.testing.expect(!fixture.pane.prepared_transfers.holds(key));
    try std.testing.expect(!objectExists(parked_name));
    try std.testing.expectEqual(used_before, fixture.pane.media_allocator.used);
}

test "a media reset invalidates every attached client before staging" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var second: AttachmentStore = .{};
    _ = try second.attach(std.testing.allocator, fixture.pane);
    defer second.deinit();
    const stores = [_]*AttachmentStore{ &fixture.attachments, &second };

    const stats = synchronize(fixture.pane, &stores, true);

    try std.testing.expectEqual(@as(u64, 0), stats.staged);
    try std.testing.expect(fixture.attachments.find(fixture.pane.id).?.hasGraphicsWork());
    try std.testing.expect(second.find(fixture.pane.id).?.hasGraphicsWork());
    try std.testing.expect(!fixture.attachments.find(fixture.pane.id).?.hasFrozenGraphics());
    try std.testing.expect(!second.find(fixture.pane.id).?.hasFrozenGraphics());
}

test "one idle-boundary pass freezes at most one transfer per client" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fixture.addRgbaImage(7);
    fixture.pane.refreshGraphicsProjection();
    const stores = [_]*AttachmentStore{&fixture.attachments};

    const first = synchronize(fixture.pane, &stores, false);
    const second = synchronize(fixture.pane, &stores, false);

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    try std.testing.expectEqual(@as(u64, 1), first.staged);
    try std.testing.expectEqual(@as(u64, 0), second.staged);
    try std.testing.expect(attachment.hasFrozenGraphics());
}

test "a failed freeze abandons only its client graphics projection" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fixture.addRgbaImage(7);
    fixture.pane.refreshGraphicsProjection();
    fixture.failNextAttachmentAllocation();
    const stores = [_]*AttachmentStore{&fixture.attachments};

    const stats = synchronize(fixture.pane, &stores, false);

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    try std.testing.expectEqual(@as(u64, 0), stats.staged);
    try std.testing.expect(!attachment.hasFrozenGraphics());
    try std.testing.expect(attachment.graphicsCaughtUp());
}
