//! Cell projection contracts across pane and client attachment state.

const PaneFixture = @import("PaneFixture.zig");
const Attachment = @import("../attachment/Attachment.zig");
const FrameViewType = @import("telar-core").FrameView;
const std = @import("std");
const decodeServer_module = @import("telar-core").decodeServer;
const enabled_module = @import("telar-core").enabled;

fn prepareFrame(fixture: *PaneFixture, attachment: *Attachment, buffer: []u8) !FrameViewType {
    const prepared = (try attachment.prepareNextCells(.{
        .io = std.testing.io,
        .buffer = buffer,
        .metrics = &fixture.metrics,
    })).?;
    const message = try decodeServer_module(prepared.bytes);

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
    try std.testing.expectEqual(noops_before + @intFromBool(enabled_module), fixture.metrics.noop_frames);

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

test "text metadata replacements follow each client's acknowledged frame without queuing" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const current = fixture.attachments.find(fixture.pane.id).?;
    var other = try Attachment.init(std.testing.allocator, fixture.pane);
    defer other.deinit();
    var current_buffer: [16 * 1024]u8 = undefined;
    var other_buffer: [16 * 1024]u8 = undefined;
    try establishBaseline(&fixture, current, &current_buffer);
    try establishBaseline(&fixture, &other, &other_buffer);
    _ = try fixture.pane.ingest(std.testing.io, "\x1b[H\x1b]8;;https://first.example\x1b\\x\x1b]8;;\x1b\\");
    const first = try prepareFrame(&fixture, current, &current_buffer);
    try std.testing.expectEqualStrings("https://first.example", first.text_metadata.?.link(0).?);
    _ = try fixture.pane.ingest(std.testing.io, "\x1b[H\x1b]8;;https://latest.example\x1b\\x\x1b]8;;\x1b\\");
    try std.testing.expect((try current.prepareNextCells(.{ .io = std.testing.io, .buffer = &current_buffer, .metrics = &fixture.metrics })) == null);
    const other_frame = try prepareFrame(&fixture, &other, &other_buffer);
    try std.testing.expectEqualStrings("https://latest.example", other_frame.text_metadata.?.link(0).?);
    try std.testing.expect(current.cells.acknowledge(first.frame_id, first.frame_id) != null);
    const latest = try prepareFrame(&fixture, current, &current_buffer);
    try std.testing.expectEqual(first.frame_id, latest.base_frame_id);
    try std.testing.expectEqualStrings("https://latest.example", latest.text_metadata.?.link(0).?);
    var spans = latest.spans();
    try std.testing.expect((try spans.next()) == null);
    try std.testing.expect(current.cells.acknowledge(latest.frame_id, latest.frame_id) != null);
    _ = try fixture.pane.ingest(std.testing.io, "\x1b[Hx");
    const cleared = try prepareFrame(&fixture, current, &current_buffer);
    try std.testing.expectEqual(latest.frame_id, cleared.base_frame_id);
    try std.testing.expectEqual(@as(u16, 0), cleared.text_metadata.?.link_count);
    var cleared_spans = cleared.spans();
    try std.testing.expect((try cleared_spans.next()) == null);
}

test "historical text metadata stays client-local and snapshots restore the active viewport" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const attachment = fixture.attachments.find(fixture.pane.id).?;
    _ = try fixture.pane.ingest(std.testing.io, "\x1b]8;;https://history.example\x1b\\old\x1b]8;;\x1b\\\r\none\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix\r\nseven\r\n");
    try fixture.pane.render(false);
    try std.testing.expectEqual(@as(u16, 0), fixture.pane.text_metadata.current.view().link_count);
    try std.testing.expect(try attachment.cells.setViewport(fixture.pane, 0));
    var bytes: [16 * 1024]u8 = undefined;
    const historical = try prepareFrame(&fixture, attachment, &bytes);
    try std.testing.expectEqual(@as(u64, 0), historical.base_frame_id);
    try std.testing.expectEqual(@as(u32, 0), historical.scroll.offset);
    try std.testing.expectEqualStrings("https://history.example", historical.text_metadata.?.link(0).?);
    try std.testing.expectEqual(@as(u16, 0), fixture.pane.text_metadata.current.view().link_count);
    const scrollbar = fixture.pane.terminal.screens.active.pages.scrollbar();
    try std.testing.expect(scrollbar.offset + scrollbar.len >= scrollbar.total);
    try std.testing.expect(try attachment.cells.setViewport(fixture.pane, std.math.maxInt(u32)));
    const active = try prepareFrame(&fixture, attachment, &bytes);
    try std.testing.expectEqual(@as(u64, 0), active.base_frame_id);
    try std.testing.expectEqual(@as(u16, 0), active.text_metadata.?.link_count);
    try std.testing.expectEqual(fixture.pane.screen.h, active.text_metadata.?.rows.len);
}
