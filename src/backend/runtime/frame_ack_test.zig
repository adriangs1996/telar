//! Vertical and application tests for pane frame acknowledgements.

const std = @import("std");
const core = @import("telar-core");
const frame_ack_commands = @import("commands/frame_ack.zig");
const frame_ack_controller = @import("controllers/frame_ack.zig");
const test_support = @import("test_support.zig");

const schema = core.schema;
const diagnostics = core.diagnostics;
const PaneFixture = test_support.PaneFixture;
const AckController = frame_ack_controller.Controller(*frame_ack_commands.FrameAckHandler);

fn prepareOutstandingFrame(fixture: *PaneFixture, buffer: []u8) !u64 {
    const attachment = fixture.attachments.find(fixture.pane.id).?;
    const prepared = (try attachment.prepareNextCells(.{
        .io = std.testing.io,
        .buffer = buffer,
        .metrics = &fixture.metrics,
    })).?;
    const message = try schema.decodeServer(prepared.bytes);
    const frame = switch (message) {
        .pane_frame => |value| value,
        else => return error.ExpectedPaneFrame,
    };

    try std.testing.expectEqual(frame.frame_id, attachment.outstandingFrameId());
    return frame.frame_id;
}

test "FrameAckHandler accepts only the exact outstanding frame" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    var buffer: [16 * 1024]u8 = undefined;
    const frame_id = try prepareOutstandingFrame(&fixture, &buffer);
    const attachment = fixture.attachments.find(fixture.pane.id).?;
    const received_at_ns = attachment.cells.outstanding.?.sent_ns + 37;
    var handler: frame_ack_commands.FrameAckHandler = .{
        .attachments = &fixture.attachments,
    };

    const result = try handler.execute(.{
        .pane_id = fixture.pane.id,
        .frame_id = frame_id,
        .received_at_ns = received_at_ns,
    });

    switch (result) {
        .acknowledged => |elapsed| try std.testing.expectEqual(@as(u64, 37), elapsed),
        .stale => return error.ExpectedAcknowledgedFrame,
    }
    try std.testing.expectEqual(@as(u64, 0), attachment.outstandingFrameId());
    try std.testing.expectEqual(frame_id, attachment.cells.acknowledged_frame_id);
}

test "FrameAckHandler leaves another pane's outstanding frame untouched" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    var buffer: [16 * 1024]u8 = undefined;
    const frame_id = try prepareOutstandingFrame(&fixture, &buffer);
    const attachment = fixture.attachments.find(fixture.pane.id).?;
    var handler: frame_ack_commands.FrameAckHandler = .{
        .attachments = &fixture.attachments,
    };

    const result = try handler.execute(.{
        .pane_id = try schema.id.pane(99),
        .frame_id = frame_id,
        .received_at_ns = std.math.maxInt(u64),
    });

    try std.testing.expectEqual(std.meta.Tag(frame_ack_commands.FrameAckResult).stale, std.meta.activeTag(result));
    try std.testing.expectEqual(frame_id, attachment.outstandingFrameId());
    try std.testing.expectEqual(@as(u64, 0), attachment.cells.acknowledged_frame_id);
}

test "FrameAckHandler rejects future obsolete and duplicate frame IDs" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    var buffer: [16 * 1024]u8 = undefined;
    const obsolete_frame_id = try prepareOutstandingFrame(&fixture, &buffer);
    try std.testing.expect(fixture.attachments.requestCellSnapshot(fixture.pane.id));
    const current_frame_id = try prepareOutstandingFrame(&fixture, &buffer);
    const attachment = fixture.attachments.find(fixture.pane.id).?;
    var handler: frame_ack_commands.FrameAckHandler = .{
        .attachments = &fixture.attachments,
    };

    for ([_]u64{ current_frame_id + 1, obsolete_frame_id }) |frame_id| {
        const stale = try handler.execute(.{
            .pane_id = fixture.pane.id,
            .frame_id = frame_id,
            .received_at_ns = std.math.maxInt(u64),
        });

        try std.testing.expectEqual(std.meta.Tag(frame_ack_commands.FrameAckResult).stale, std.meta.activeTag(stale));
        try std.testing.expectEqual(current_frame_id, attachment.outstandingFrameId());
    }

    const accepted = try handler.execute(.{
        .pane_id = fixture.pane.id,
        .frame_id = current_frame_id,
        .received_at_ns = std.math.maxInt(u64),
    });
    try std.testing.expectEqual(std.meta.Tag(frame_ack_commands.FrameAckResult).acknowledged, std.meta.activeTag(accepted));

    const duplicate = try handler.execute(.{
        .pane_id = fixture.pane.id,
        .frame_id = current_frame_id,
        .received_at_ns = std.math.maxInt(u64),
    });
    try std.testing.expectEqual(std.meta.Tag(frame_ack_commands.FrameAckResult).stale, std.meta.activeTag(duplicate));
    try std.testing.expectEqual(@as(u64, 0), attachment.outstandingFrameId());
    try std.testing.expectEqual(current_frame_id, attachment.cells.acknowledged_frame_id);
}

test "an accepted ACK preserves a pending recovery snapshot" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    var buffer: [16 * 1024]u8 = undefined;
    const acknowledged_frame_id = try prepareOutstandingFrame(&fixture, &buffer);
    const attachment = fixture.attachments.find(fixture.pane.id).?;
    try std.testing.expect(fixture.attachments.requestCellSnapshot(fixture.pane.id));
    var handler: frame_ack_commands.FrameAckHandler = .{
        .attachments = &fixture.attachments,
    };

    const result = try handler.execute(.{
        .pane_id = fixture.pane.id,
        .frame_id = acknowledged_frame_id,
        .received_at_ns = std.math.maxInt(u64),
    });

    try std.testing.expectEqual(std.meta.Tag(frame_ack_commands.FrameAckResult).acknowledged, std.meta.activeTag(result));
    try std.testing.expect(attachment.cells.snapshot_pending);
    const recovery_frame_id = try prepareOutstandingFrame(&fixture, &buffer);
    try std.testing.expect(recovery_frame_id > acknowledged_frame_id);
    try std.testing.expectEqual(recovery_frame_id, attachment.outstandingFrameId());
}

test "frame ACK crosses controller and handler and records only accepted latency" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    var buffer: [16 * 1024]u8 = undefined;
    const frame_id = try prepareOutstandingFrame(&fixture, &buffer);
    const attachment = fixture.attachments.find(fixture.pane.id).?;
    var handler: frame_ack_commands.FrameAckHandler = .{
        .attachments = &fixture.attachments,
    };
    var controller = AckController.init(std.testing.io, &fixture.metrics, &handler);

    try controller.frameAck(.{ .pane_id = fixture.pane.id, .frame_id = frame_id });

    try std.testing.expectEqual(@as(u64, 0), attachment.outstandingFrameId());
    try std.testing.expectEqual(@as(u64, 0), fixture.metrics.stale_client_messages);
    try std.testing.expectEqual(@as(u64, if (diagnostics.enabled) 1 else 0), fixture.metrics.ack.count);
}
