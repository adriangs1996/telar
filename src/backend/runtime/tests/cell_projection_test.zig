//! Cell projection contracts across pane and client attachment state.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../attachment/root.zig");
const test_support = @import("support.zig");

const schema = core.schema;
const diagnostics = core.diagnostics;
const Attachment = attachment_mod.Attachment;
const PaneFixture = test_support.PaneFixture;

fn prepareFrame(fixture: *PaneFixture, attachment: *Attachment, buffer: []u8) !schema.frame.FrameView {
    const prepared = (try attachment.prepareNextCells(.{
        .io = std.testing.io,
        .buffer = buffer,
        .metrics = &fixture.metrics,
    })).?;
    const message = try schema.decodeServer(prepared.bytes);

    return switch (message) {
        .pane_frame => |frame| frame,
        else => error.ExpectedPaneFrame,
    };
}

fn establishBaseline(fixture: *PaneFixture, attachment: *Attachment, buffer: []u8) !void {
    const frame = try prepareFrame(fixture, attachment, buffer);
    const received_at_ns = attachment.cells.outstanding.?.sent_ns +| 1;

    try std.testing.expect(attachment.cells.acknowledge(frame.frame_id, received_at_ns) != null);
}

test "a no-op projection advances its observed revision and is not prepared twice" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    var buffer: [16 * 1024]u8 = undefined;
    try establishBaseline(&fixture, attachment, &buffer);
    @memset(fixture.pane.damaged_rows, false);
    fixture.pane.dirty = false;

    const previous_revision = fixture.pane.cell_revision;
    _ = try fixture.pane.ingest(std.testing.io, "\x07");
    const noops_before = fixture.metrics.noop_frames;

    try std.testing.expect((try attachment.prepareNextCells(.{
        .io = std.testing.io,
        .buffer = &buffer,
        .metrics = &fixture.metrics,
    })) == null);
    try std.testing.expect(fixture.pane.cell_revision != previous_revision);
    try std.testing.expectEqual(fixture.pane.cell_revision, attachment.observedCellRevision());
    try std.testing.expectEqual(noops_before + @intFromBool(diagnostics.enabled), fixture.metrics.noop_frames);

    const noops_after_observation = fixture.metrics.noop_frames;

    try std.testing.expect((try attachment.prepareNextCells(.{
        .io = std.testing.io,
        .buffer = &buffer,
        .metrics = &fixture.metrics,
    })) == null);
    try std.testing.expectEqual(noops_after_observation, fixture.metrics.noop_frames);

    _ = try fixture.pane.ingest(std.testing.io, "x");

    try std.testing.expect((try attachment.prepareNextCells(.{
        .io = std.testing.io,
        .buffer = &buffer,
        .metrics = &fixture.metrics,
    })) != null);
}

test "a current attachment skips retained damage while a stale attachment receives it" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const current = fixture.attachments.find(fixture.pane.id).?;
    var stale = try Attachment.init(std.testing.allocator, fixture.pane);
    defer stale.deinit();
    var current_buffer: [16 * 1024]u8 = undefined;
    var stale_buffer: [16 * 1024]u8 = undefined;
    try establishBaseline(&fixture, current, &current_buffer);
    try establishBaseline(&fixture, &stale, &stale_buffer);
    @memset(fixture.pane.damaged_rows, false);
    fixture.pane.dirty = false;

    _ = try fixture.pane.ingest(std.testing.io, "visible");
    const current_frame = try prepareFrame(&fixture, current, &current_buffer);
    const received_at_ns = current.cells.outstanding.?.sent_ns +| 1;

    try std.testing.expect(current.cells.acknowledge(current_frame.frame_id, received_at_ns) != null);
    try std.testing.expect(fixture.pane.dirty);
    try std.testing.expectEqual(fixture.pane.cell_revision, current.observedCellRevision());
    try std.testing.expect(stale.observedCellRevision() != fixture.pane.cell_revision);

    const noops_before = fixture.metrics.noop_frames;

    try std.testing.expect((try current.prepareNextCells(.{
        .io = std.testing.io,
        .buffer = &current_buffer,
        .metrics = &fixture.metrics,
    })) == null);
    try std.testing.expectEqual(noops_before, fixture.metrics.noop_frames);

    const stale_frame = try prepareFrame(&fixture, &stale, &stale_buffer);

    try std.testing.expectEqual(fixture.pane.cell_revision, stale.observedCellRevision());
    try std.testing.expect(stale_frame.frame_id != 0);
}
