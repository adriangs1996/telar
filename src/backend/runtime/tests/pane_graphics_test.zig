//! Each client's graphics projection of one pane: staging and freezing
//! transfers, adopting what the media actor parked, and releasing what no
//! client can still use.

const core = @import("telar-core");
const std = @import("std");
const PaneFixture = @import("PaneFixture.zig");
const StatsType = @import("../../media/Stats.zig");
const attachment_namespace = @import("../attachment/attachment_namespace.zig");
const pane_graphics = @import("../pane_graphics.zig");
const shared_transfer_module = @import("../../media/shared_transfer.zig");
const synchronize = pane_graphics.synchronize;

fn objectExists(name: core.ShmName) bool {
    const fd = std.c.shm_open(name.sliceZ(), @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })), @as(u16, 0));
    if (std.posix.errno(fd) != .SUCCESS) {
        return false;
    }
    _ = std.c.close(fd);
    return true;
}

fn liveKey(fixture: *PaneFixture, image_id: u32) core.ImageKey {
    const image = fixture.pane.media.terminal.screens.active.kitty_images.imageById(image_id).?;
    return .{ .image_id = image.id, .generation = image.generation };
}

test "shared transport clients are counted on the pane for the media actor" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    try std.testing.expectEqual(@as(u8, 0), fixture.pane.media_ingestion.shared_transport_clients.load(.acquire));
    fixture.attachment().configureGraphics(true);
    try std.testing.expectEqual(@as(u8, 1), fixture.pane.media_ingestion.shared_transport_clients.load(.acquire));
    fixture.attachment().configureGraphics(true);
    try std.testing.expectEqual(@as(u8, 1), fixture.pane.media_ingestion.shared_transport_clients.load(.acquire));
    fixture.attachment().configureGraphics(false);
    try std.testing.expectEqual(@as(u8, 0), fixture.pane.media_ingestion.shared_transport_clients.load(.acquire));
}

test "a generation the media actor froze is adopted without a runtime-thread copy" {
    if (comptime !shared_transfer_module.shared_memory_supported) {
        return error.SkipZigTest;
    }
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    fixture.attachment().configureGraphics(true);
    try fixture.addRgbaImage(7);
    const key = liveKey(&fixture, 7);

    var stats: StatsType = .{};
    fixture.pane.prepareSharedTransfers(&stats);

    try std.testing.expectEqual(@as(u64, 1), stats.prepared_frames);
    try std.testing.expect(fixture.pane.media_ingestion.prepared_transfers.holds(key));
    const used_before = fixture.pane.media_allocator.used;
    fixture.pane.refreshGraphicsProjection();

    const projection = synchronize(&fixture.attachments, fixture.pane, false);

    const attachment = fixture.attachment();
    try std.testing.expectEqual(@as(u64, 1), projection.staged);
    try std.testing.expect(attachment.hasFrozenGraphics());
    const transfer = attachment.graphics.transfer.?;
    try std.testing.expect(transfer.shared_name != null);
    try std.testing.expect(objectExists(transfer.shared_name.?));
    try std.testing.expectEqual(@as(u32, 1), attachment.graphics.adopted);
    try std.testing.expectEqual(@as(u64, 0), attachment.graphics.freeze.count);
    try std.testing.expect(!fixture.pane.media_ingestion.prepared_transfers.holds(key));
    // The actor's reservation moved to the transfer instead of doubling.
    try std.testing.expectEqual(used_before, fixture.pane.media_allocator.used);

    // A second batch offers nothing for a generation already handed out.
    var again: StatsType = .{};
    fixture.pane.prepareSharedTransfers(&again);
    try std.testing.expectEqual(@as(u64, 0), again.prepared_frames);
}

test "a replaced generation releases the object the actor parked for it" {
    if (comptime !shared_transfer_module.shared_memory_supported) {
        return error.SkipZigTest;
    }
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    fixture.attachment().configureGraphics(true);
    try fixture.addRgbaImage(7);
    var first: StatsType = .{};
    fixture.pane.prepareSharedTransfers(&first);
    const first_key = liveKey(&fixture, 7);
    const first_name = fixture.pane.media_ingestion.prepared_transfers.take(first_key).?.name;
    try std.testing.expect(fixture.pane.media_ingestion.prepared_transfers.put(.{
        .metadata = .{ .key = first_key, .format = .rgba, .width = 1, .height = 1, .byte_len = 4 },
        .name = first_name,
        .reserved_len = 4,
    }, &fixture.pane.media_allocator));
    const used_before = fixture.pane.media_allocator.used;

    try fixture.addRgbaImage(7);
    var second: StatsType = .{};
    fixture.pane.prepareSharedTransfers(&second);

    const second_key = liveKey(&fixture, 7);
    try std.testing.expect(second_key.generation != first_key.generation);
    try std.testing.expectEqual(@as(u64, 1), second.prepared_frames);
    try std.testing.expect(!objectExists(first_name));
    try std.testing.expect(!fixture.pane.media_ingestion.prepared_transfers.holds(first_key));
    try std.testing.expect(fixture.pane.media_ingestion.prepared_transfers.holds(second_key));
    try std.testing.expectEqual(used_before, fixture.pane.media_allocator.used);
}

test "parked generations every client already knows are released at synchronization" {
    if (comptime !shared_transfer_module.shared_memory_supported) {
        return error.SkipZigTest;
    }
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    fixture.attachment().configureGraphics(true);
    try fixture.addRgbaImage(7);
    const key = liveKey(&fixture, 7);
    const attachment = fixture.attachment();
    try attachment_namespace.rememberImage(attachment, key);
    fixture.pane.refreshGraphicsProjection();
    attachment.graphics.observed_revision = fixture.pane.graphics_revision;
    const used_before = fixture.pane.media_allocator.used;
    var stats: StatsType = .{};
    fixture.pane.prepareSharedTransfers(&stats);
    const parked_name = fixture.pane.media_ingestion.prepared_transfers.items[0].?.name;

    const projection = synchronize(&fixture.attachments, fixture.pane, false);

    try std.testing.expectEqual(@as(u64, 0), projection.staged);
    try std.testing.expect(!attachment.hasFrozenGraphics());
    try std.testing.expect(!fixture.pane.media_ingestion.prepared_transfers.holds(key));
    try std.testing.expect(!objectExists(parked_name));
    try std.testing.expectEqual(used_before, fixture.pane.media_allocator.used);
}

test "detach releases a parked fallback and its quota before another consumer arrives" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fixture.addRgbaImage(63);
    fixture.pane.refreshGraphicsProjection();
    _ = synchronize(&fixture.attachments, fixture.pane, false);
    fixture.processMedia();
    const parked_bytes = fixture.pane.media_allocator.used;
    try std.testing.expect(fixture.pane.media_ingestion.transfer_preparation.entries[0] != null);
    _ = fixture.attachments.remove(fixture.attachment_allocator.allocator(), PaneFixture.client, fixture.pane.id);
    _ = synchronize(&fixture.attachments, fixture.pane, false);
    try std.testing.expectEqual(parked_bytes - 4, fixture.pane.media_allocator.used);
    for (fixture.pane.media_ingestion.transfer_preparation.entries) |entry| {
        try std.testing.expect(entry == null);
    }
}

test "missing generations release all bounded transfer request slots" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const queue = &fixture.pane.media_ingestion.transfer_preparation;
    for (0..8) |index| {
        try std.testing.expect(queue.request(.{
            .key = .{ .image_id = @intCast(index + 1), .generation = 99 },
            .shared_transport = false,
            .allocator = std.testing.allocator,
        }));
    }
    try std.testing.expect(!queue.request(.{ .key = .{ .image_id = 99, .generation = 99 }, .shared_transport = false, .allocator = std.testing.allocator }));
    queue.process(&fixture.pane.media.terminal.screens.active.kitty_images, &fixture.pane.media_allocator);
    for (queue.entries) |entry| {
        try std.testing.expect(entry == null);
    }
}

test "a media reset invalidates every attached client before staging" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const second_client = PaneFixture.client + 1;
    const second = try fixture.attachments.add(fixture.attachment_allocator.allocator(), second_client, fixture.pane);

    const stats = synchronize(&fixture.attachments, fixture.pane, true);

    try std.testing.expectEqual(@as(u64, 0), stats.staged);
    try std.testing.expect(fixture.attachment().hasGraphicsWork());
    try std.testing.expect(second.hasGraphicsWork());
    try std.testing.expect(!fixture.attachment().hasFrozenGraphics());
    try std.testing.expect(!second.hasFrozenGraphics());
}

test "one idle-boundary pass freezes at most one transfer per client" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fixture.addRgbaImage(7);
    fixture.pane.refreshGraphicsProjection();

    try std.testing.expectEqual(@as(u64, 0), synchronize(&fixture.attachments, fixture.pane, false).staged);
    fixture.processMedia();
    const first = synchronize(&fixture.attachments, fixture.pane, false);
    const second = synchronize(&fixture.attachments, fixture.pane, false);

    const attachment = fixture.attachment();
    try std.testing.expectEqual(@as(u64, 1), first.staged);
    try std.testing.expectEqual(@as(u64, 0), second.staged);
    try std.testing.expect(attachment.hasFrozenGraphics());
}

test "a failed freeze abandons only its client graphics projection" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fixture.addRgbaImage(7);
    fixture.pane.refreshGraphicsProjection();
    fixture.failNextAttachmentAllocation();
    _ = synchronize(&fixture.attachments, fixture.pane, false);
    fixture.processMedia();

    const stats = synchronize(&fixture.attachments, fixture.pane, false);

    const attachment = fixture.attachment();
    try std.testing.expectEqual(@as(u64, 0), stats.staged);
    try std.testing.expect(!attachment.hasFrozenGraphics());
    try std.testing.expect(attachment.graphicsCaughtUp());
}

fn expectCursor(fixture: *PaneFixture, x: usize, y: usize) !void {
    const cursor = fixture.pane.terminal.screens.active.cursor;
    try std.testing.expectEqual(x, cursor.x);
    try std.testing.expectEqual(y, cursor.y);
}

test "the interactive terminal moves its cursor past a placement like the media terminal" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    // Two rows high, three columns wide: down one row, right three columns.
    _ = try fixture.pane.ingest(std.testing.io, "ab\x1b_Ga=T,f=24,s=1,v=1,c=3,r=2,i=5,q=2;AAAA\x1b\\");
    try expectCursor(&fixture, 5, 1);

    // C=1 keeps the cursor where the image was placed.
    _ = try fixture.pane.ingest(std.testing.io, "\x1b_Ga=p,i=5,c=3,r=2,C=1,q=2\x1b\\");
    try expectCursor(&fixture, 5, 1);

    // Reaching the right edge wraps once to the first column.
    _ = try fixture.pane.ingest(std.testing.io, "\x1b[1;19H\x1b_Ga=p,i=5,c=3,r=2,q=2\x1b\\");
    try expectCursor(&fixture, 0, 2);

    // A chunked transmission moves once, when its last chunk arrives, even
    // when the terminator splits across reads.
    _ = try fixture.pane.ingest(std.testing.io, "\x1b[1;1H\x1b_Ga=T,f=24,s=1,v=1,c=1,r=3,m=1,q=2;AAAA\x1b\\");
    try expectCursor(&fixture, 0, 0);
    _ = try fixture.pane.ingest(std.testing.io, "\x1b_Gm=0;AAAA\x1b");
    try expectCursor(&fixture, 0, 0);
    _ = try fixture.pane.ingest(std.testing.io, "\\");
    try expectCursor(&fixture, 1, 2);
}
