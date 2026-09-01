//! Vertical and application tests for graphics snapshot recovery.

const std = @import("std");
const core = @import("telar-core");
const request_graphics_snapshot_commands = @import("../application/commands/request_graphics_snapshot.zig");
const request_graphics_snapshot_controller = @import("../entrypoints/requests/request_graphics_snapshot.zig");
const test_support = @import("support.zig");

const schema = core.schema;
const PaneFixture = test_support.PaneFixture;
const GraphicsSnapshotController = request_graphics_snapshot_controller.Controller(*request_graphics_snapshot_commands.RequestGraphicsSnapshotHandler);

test "RequestGraphicsSnapshotHandler discards transfer state and preserves transport policy" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    const key: core.graphics.ImageKey = .{ .image_id = 7, .generation = 3 };
    attachment.graphics.snapshot = .idle;
    attachment.graphics.revision = 11;
    attachment.graphics.target_revision = 10;
    attachment.graphics.batch_active = true;
    attachment.graphics.observed_revision = 9;
    attachment.graphics.credit = 41;
    attachment.graphics.shared_transport = true;
    attachment.graphics.known_images[0] = .{ .key = key };
    attachment.graphics.known_placements[0] = .{ .placement = .{
        .key = key,
        .virtual_id = 5,
        .placement_id = 2,
        .x = 1,
        .y = 2,
    } };

    const transfer_bytes = 4;
    const media_used_before = fixture.pane.media_allocator.used;
    try std.testing.expect(fixture.pane.media_allocator.reserveManual(transfer_bytes));
    const pixels = try attachment.graphics.gpa.dupe(u8, &.{ 1, 2, 3, 4 });
    attachment.graphics.transfer = .{
        .metadata = .{
            .key = key,
            .format = .rgba,
            .width = 1,
            .height = 1,
            .byte_len = transfer_bytes,
        },
        .pixels = pixels,
        .reserved_len = transfer_bytes,
    };

    var handler: request_graphics_snapshot_commands.RequestGraphicsSnapshotHandler = .{
        .attachments = &fixture.attachments,
    };

    try std.testing.expectEqual(
        request_graphics_snapshot_commands.RequestGraphicsSnapshotResult.requested,
        try handler.execute(.{ .pane_id = fixture.pane.id }),
    );
    try std.testing.expectEqual(
        request_graphics_snapshot_commands.RequestGraphicsSnapshotResult.requested,
        try handler.execute(.{ .pane_id = fixture.pane.id }),
    );

    try std.testing.expectEqual(.begin_pending, attachment.graphics.snapshot);
    try std.testing.expectEqual(@as(u64, 11), attachment.graphics.revision);
    try std.testing.expectEqual(@as(u64, 0), attachment.graphics.target_revision);
    try std.testing.expect(!attachment.graphics.batch_active);
    try std.testing.expectEqual(@as(u64, 0), attachment.graphics.observed_revision);
    try std.testing.expectEqual(@as(usize, 41), attachment.graphics.credit);
    try std.testing.expect(attachment.graphics.shared_transport);
    try std.testing.expect(attachment.graphics.transfer == null);
    try std.testing.expect(attachment.graphics.known_images[0] == null);
    try std.testing.expect(attachment.graphics.known_placements[0] == null);
    try std.testing.expectEqual(media_used_before, fixture.pane.media_allocator.used);
}

test "RequestGraphicsSnapshotHandler leaves other attachments unchanged" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    attachment.graphics.snapshot = .idle;
    attachment.graphics.target_revision = 12;
    attachment.graphics.batch_active = true;
    attachment.graphics.observed_revision = 11;
    var handler: request_graphics_snapshot_commands.RequestGraphicsSnapshotHandler = .{
        .attachments = &fixture.attachments,
    };

    const result = try handler.execute(.{ .pane_id = try schema.id.pane(99) });

    try std.testing.expectEqual(request_graphics_snapshot_commands.RequestGraphicsSnapshotResult.pane_not_attached, result);
    try std.testing.expectEqual(.idle, attachment.graphics.snapshot);
    try std.testing.expectEqual(@as(u64, 12), attachment.graphics.target_revision);
    try std.testing.expect(attachment.graphics.batch_active);
    try std.testing.expectEqual(@as(u64, 11), attachment.graphics.observed_revision);
}

test "graphics recovery crosses controller and handler without stale accounting" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    attachment.graphics.snapshot = .idle;
    var handler: request_graphics_snapshot_commands.RequestGraphicsSnapshotHandler = .{
        .attachments = &fixture.attachments,
    };
    var controller = GraphicsSnapshotController.init(&fixture.metrics, &handler);

    try controller.requestGraphicsSnapshot(.{ .pane_id = fixture.pane.id });

    try std.testing.expectEqual(.begin_pending, attachment.graphics.snapshot);
    try std.testing.expectEqual(@as(u64, 0), fixture.metrics.stale_client_messages);
}

test "repeated recovery requests emit one complete empty graphics snapshot" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    var handler: request_graphics_snapshot_commands.RequestGraphicsSnapshotHandler = .{
        .attachments = &fixture.attachments,
    };
    var controller = GraphicsSnapshotController.init(&fixture.metrics, &handler);
    try controller.requestGraphicsSnapshot(.{ .pane_id = fixture.pane.id });
    try controller.requestGraphicsSnapshot(.{ .pane_id = fixture.pane.id });

    var buffer: [1024]u8 = undefined;
    const credit = fixture.attachments.availableGraphicsCredit();
    const begin = (try attachment.prepareNextGraphics(.{
        .buffer = &buffer,
        .global_credit = credit,
        .live_storage_available = true,
    })).?;
    const begin_message = try schema.decodeServer(begin.bytes);
    const begin_effect = attachment.commitPrepared(begin);

    try std.testing.expect(begin_message == .graphics_snapshot);
    try std.testing.expect(begin_message.graphics_snapshot.phase == .begin);
    try std.testing.expect(begin_effect.graphics_message);

    const end = (try attachment.prepareNextGraphics(.{
        .buffer = &buffer,
        .global_credit = credit,
        .live_storage_available = true,
    })).?;
    const end_message = try schema.decodeServer(end.bytes);
    const end_effect = attachment.commitPrepared(end);

    try std.testing.expect(end_message == .graphics_snapshot);
    try std.testing.expect(end_message.graphics_snapshot.phase == .end);
    try std.testing.expect(end_effect.graphics_message);
    try std.testing.expect((try attachment.prepareNextGraphics(.{
        .buffer = &buffer,
        .global_credit = credit,
        .live_storage_available = true,
    })) == null);
    try std.testing.expectEqual(.idle, attachment.graphics.snapshot);
    try std.testing.expect(!attachment.graphics.batch_active);
    try std.testing.expectEqual(fixture.pane.graphics_revision, attachment.graphics.observed_revision);
}
