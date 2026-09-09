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
    const received_at_ns = attachment.cells.lastSentNs().? +| 1;

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
    const received_at_ns = current.cells.lastSentNs().? +| 1;

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

test "a moved viewport is delivered as a patch against the acknowledged frame" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    _ = try fixture.pane.ingest(
        std.testing.io,
        "zero\r\none\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix\r\nseven\r\n",
    );
    try fixture.pane.render(false);

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    var buffer: [16 * 1024]u8 = undefined;
    try establishBaseline(&fixture, attachment, &buffer);
    const baseline_frame_id = attachment.cells.acknowledged_frame_id;
    const snapshots_before = fixture.metrics.snapshots;

    try std.testing.expect((try fixture.attachments.setPaneViewport(.{ .pane_id = fixture.pane.id, .offset = 0 })).? == .changed);
    try std.testing.expect(attachment.cells.viewport_moved);
    try std.testing.expect(!attachment.cells.snapshot_pending);

    const scrolled = try prepareFrame(&fixture, attachment, &buffer);
    try std.testing.expectEqual(baseline_frame_id, scrolled.base_frame_id);
    try std.testing.expectEqual(@as(u32, 0), scrolled.scroll.offset);
    try std.testing.expect(!attachment.cells.viewport_moved);
    try std.testing.expectEqual(snapshots_before, fixture.metrics.snapshots);
    var scrolled_spans = scrolled.spans();
    try std.testing.expect((try scrolled_spans.next()) != null);

    const received_at_ns = attachment.cells.lastSentNs().? +| 1;
    try std.testing.expect(attachment.cells.acknowledge(scrolled.frame_id, received_at_ns) != null);

    // Returning to the live screen leaves the pin and projects from the pane
    // screen; the frame still diffs every row against the scrolled baseline.
    try std.testing.expect((try fixture.attachments.setPaneViewport(.{ .pane_id = fixture.pane.id, .offset = std.math.maxInt(u32) })).? == .changed);
    try std.testing.expect(attachment.cells.viewport_pin == null);
    const restored = try prepareFrame(&fixture, attachment, &buffer);
    try std.testing.expectEqual(scrolled.frame_id, restored.base_frame_id);
    var restored_spans = restored.spans();
    try std.testing.expect((try restored_spans.next()) != null);
    try std.testing.expectEqual(snapshots_before, fixture.metrics.snapshots);
}

test "two dependent patches may be in flight and one acknowledgement releases both" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    var buffer: [16 * 1024]u8 = undefined;
    try establishBaseline(&fixture, attachment, &buffer);
    const baseline_frame_id = attachment.cells.acknowledged_frame_id;

    _ = try fixture.pane.ingest(std.testing.io, "a");
    const first = try prepareFrame(&fixture, attachment, &buffer);
    try std.testing.expectEqual(baseline_frame_id, first.base_frame_id);
    try std.testing.expect(!attachment.cells.windowFull());

    // The second patch is diffed against the first, not the acknowledged one.
    _ = try fixture.pane.ingest(std.testing.io, "b");
    const second = try prepareFrame(&fixture, attachment, &buffer);
    try std.testing.expectEqual(first.frame_id, second.base_frame_id);
    try std.testing.expect(attachment.cells.windowFull());
    try std.testing.expectEqual(first.frame_id, attachment.outstandingFrameId());

    // A third waits for the window.
    _ = try fixture.pane.ingest(std.testing.io, "c");
    try std.testing.expect((try attachment.prepareNextCells(.{
        .io = std.testing.io,
        .buffer = &buffer,
        .metrics = &fixture.metrics,
    })) == null);

    // The client presented both and acknowledged the newest.
    const received_at_ns = attachment.cells.lastSentNs().? +| 1;
    try std.testing.expect(attachment.cells.acknowledge(second.frame_id, received_at_ns) != null);
    try std.testing.expectEqual(@as(u64, 0), attachment.outstandingFrameId());
    try std.testing.expect(attachment.cells.acknowledge(first.frame_id, received_at_ns) == null);

    const third = try prepareFrame(&fixture, attachment, &buffer);
    try std.testing.expectEqual(second.frame_id, third.base_frame_id);
}
