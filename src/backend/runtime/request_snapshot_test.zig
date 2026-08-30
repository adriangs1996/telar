//! Vertical and application tests for cell snapshot recovery.

const std = @import("std");
const core = @import("telar-core");
const request_snapshot_commands = @import("commands/request_snapshot.zig");
const request_snapshot_controller = @import("controllers/request_snapshot.zig");
const test_support = @import("test_support.zig");

const schema = core.schema;
const PaneFixture = test_support.PaneFixture;
const SnapshotController = request_snapshot_controller.Controller(*request_snapshot_commands.RequestCellSnapshotHandler);

test "RequestCellSnapshotHandler marks an attached pane and coalesces repeats" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    attachment.cells.snapshot_pending = false;
    var handler: request_snapshot_commands.RequestCellSnapshotHandler = .{
        .attachments = &fixture.attachments,
    };

    try std.testing.expectEqual(
        request_snapshot_commands.RequestCellSnapshotResult.requested,
        try handler.execute(.{ .pane_id = fixture.pane.id }),
    );
    try std.testing.expectEqual(
        request_snapshot_commands.RequestCellSnapshotResult.requested,
        try handler.execute(.{ .pane_id = fixture.pane.id }),
    );

    try std.testing.expect(attachment.cells.snapshot_pending);
}

test "RequestCellSnapshotHandler leaves an existing attachment unchanged for another pane" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    attachment.cells.snapshot_pending = false;
    var handler: request_snapshot_commands.RequestCellSnapshotHandler = .{
        .attachments = &fixture.attachments,
    };

    const result = try handler.execute(.{ .pane_id = try schema.id.pane(99) });

    try std.testing.expectEqual(request_snapshot_commands.RequestCellSnapshotResult.pane_not_attached, result);
    try std.testing.expect(!attachment.cells.snapshot_pending);
}

test "snapshot recovery crosses controller and handler without stale accounting" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    attachment.cells.snapshot_pending = false;
    var handler: request_snapshot_commands.RequestCellSnapshotHandler = .{
        .attachments = &fixture.attachments,
    };
    var controller = SnapshotController.init(&fixture.metrics, &handler);

    try controller.requestSnapshot(.{
        .pane_id = fixture.pane.id,
        .known_frame_id = 41,
    });

    try std.testing.expect(attachment.cells.snapshot_pending);
    try std.testing.expectEqual(@as(u64, 0), fixture.metrics.stale_client_messages);
}

test "repeated recovery requests replace one outstanding frame with one full snapshot" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    var buffer: [16 * 1024]u8 = undefined;
    const initial = (try attachment.prepareNextCells(.{
        .io = std.testing.io,
        .buffer = &buffer,
        .metrics = &fixture.metrics,
    })).?;
    const initial_message = try schema.decodeServer(initial.bytes);
    const initial_frame = switch (initial_message) {
        .pane_frame => |frame| frame,
        else => return error.ExpectedPaneFrame,
    };
    const initial_frame_id = initial_frame.frame_id;
    try std.testing.expectEqual(@as(u64, 0), initial_frame.base_frame_id);

    var handler: request_snapshot_commands.RequestCellSnapshotHandler = .{
        .attachments = &fixture.attachments,
    };
    var controller = SnapshotController.init(&fixture.metrics, &handler);
    try controller.requestSnapshot(.{
        .pane_id = fixture.pane.id,
        .known_frame_id = initial_frame_id,
    });
    try controller.requestSnapshot(.{
        .pane_id = fixture.pane.id,
        .known_frame_id = 0,
    });

    const recovered = (try attachment.prepareNextCells(.{
        .io = std.testing.io,
        .buffer = &buffer,
        .metrics = &fixture.metrics,
    })).?;
    const recovered_message = try schema.decodeServer(recovered.bytes);
    const recovered_frame = switch (recovered_message) {
        .pane_frame => |frame| frame,
        else => return error.ExpectedPaneFrame,
    };

    try std.testing.expectEqual(@as(u64, 0), recovered_frame.base_frame_id);
    try std.testing.expect(recovered_frame.frame_id > initial_frame_id);
    try std.testing.expectEqual(recovered_frame.frame_id, attachment.outstandingFrameId());
    try std.testing.expectEqual(@as(u16, 1), recovered_frame.span_count);
    try std.testing.expect(!attachment.cells.snapshot_pending);
    try std.testing.expect((try attachment.prepareNextCells(.{
        .io = std.testing.io,
        .buffer = &buffer,
        .metrics = &fixture.metrics,
    })) == null);
}
