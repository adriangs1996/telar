//! Cell publication admission preserves the latest projection and input priority.

const std = @import("std");
const core = @import("telar-core");
const PaneFixture = @import("PaneFixture.zig");
const Attachment = @import("../attachment/Attachment.zig");
const PaneInputHandler = @import("../application/commands/PaneInputHandler.zig");
const PaneInputTestScheduleCapture = @import("PaneInputTestScheduleCapture.zig");

const frame_buffer_size = 16 * 1024;
const TestInterval = enum(u64) { elapsed = 1, deferred = std.time.ns_per_hour };
const TestPane = enum(u16) { background = 8 };
const GraceBudget = enum(u32) { limited = 2 };
const PreparationBudget = enum(u32) { single = 1 };

fn nextFrame(fixture: *PaneFixture, attachment: *Attachment, buffer: []u8) !?core.FrameView {
    const prepared = (try attachment.prepareNextCells(.{
        .io = std.testing.io,
        .buffer = buffer,
        .metrics = &fixture.metrics,
    })) orelse return null;
    const message = try core.decodeServer(prepared.bytes);

    return switch (message) {
        .pane_frame => |frame| frame,
        else => error.ExpectedPaneFrame,
    };
}

fn acknowledge(attachment: *Attachment, frame: core.FrameView) !void {
    const sent_ns = attachment.cells.outstanding.?.sent_ns;
    try std.testing.expect(attachment.acknowledgeFrame(frame.frame_id, sent_ns) != null);
}

fn establishBaseline(fixture: *PaneFixture, attachment: *Attachment, buffer: []u8) !void {
    const frame = (try nextFrame(fixture, attachment, buffer)).?;
    try acknowledge(attachment, frame);
}

fn deferPublication(attachment: *Attachment) void {
    attachment.cell_pacer.interval = @intFromEnum(TestInterval.deferred);
    attachment.cell_pacer.burst = 0;
    attachment.cell_pacer.credits = 0;
    attachment.cell_pacer.anchor_ns = core.monotonic(std.testing.io);
}

fn expirePublication(attachment: *Attachment) void {
    attachment.cell_pacer.interval = @intFromEnum(TestInterval.elapsed);
    attachment.cell_pacer.anchor_ns = 0;
    attachment.cell_deadline_ns = @intFromEnum(TestInterval.elapsed);
}

fn expectLeadingText(frame: core.FrameView, text: []const u8) !void {
    var spans = frame.spans();
    const span = (try spans.next()).?;
    try std.testing.expectEqual(@as(u32, 0), span.start);

    var cells = span.cells();
    for (text) |byte| {
        const cell = (try cells.next()).?;
        try std.testing.expectEqualStrings(&.{byte}, cell.text());
    }
}

test "cell publication folds output before rendering and delivers the final frame without more output" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    var buffer: [frame_buffer_size]u8 = undefined;
    try establishBaseline(&fixture, attachment, &buffer);
    deferPublication(attachment);
    const observed = attachment.observedCellRevision();
    const next_frame_id = attachment.cells.next_frame_id;
    const scanned_cells = fixture.metrics.diff_scanned_cells;

    _ = try fixture.pane.ingest(std.testing.io, "first");
    try std.testing.expect((try nextFrame(&fixture, attachment, &buffer)) == null);
    const deadline = fixture.attachments.cellDeadline().?;

    _ = try fixture.pane.ingest(std.testing.io, "\x1b[Hfinal");
    try std.testing.expect((try nextFrame(&fixture, attachment, &buffer)) == null);
    try std.testing.expectEqual(deadline, fixture.attachments.cellDeadline().?);
    try std.testing.expect(fixture.pane.render_pending);
    try std.testing.expectEqual(observed, attachment.observedCellRevision());
    try std.testing.expectEqual(next_frame_id, attachment.cells.next_frame_id);
    try std.testing.expectEqual(scanned_cells, fixture.metrics.diff_scanned_cells);
    try std.testing.expect(!attachment.cells.hasOutstanding());

    expirePublication(attachment);
    const frame = (try nextFrame(&fixture, attachment, &buffer)).?;
    try expectLeadingText(frame, "final");
    try std.testing.expect(!fixture.pane.render_pending);
    try std.testing.expectEqual(fixture.pane.cell_revision, attachment.observedCellRevision());
    try std.testing.expect(attachment.cell_deadline_ns == null);
    try acknowledge(attachment, frame);

    try std.testing.expect((try nextFrame(&fixture, attachment, &buffer)) == null);
    try std.testing.expect(fixture.attachments.cellDeadline() == null);
}

test "cell snapshot recovery bypasses an exhausted publication budget" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    var buffer: [frame_buffer_size]u8 = undefined;
    try establishBaseline(&fixture, attachment, &buffer);
    deferPublication(attachment);
    _ = try fixture.pane.ingest(std.testing.io, "recover");
    try std.testing.expect((try nextFrame(&fixture, attachment, &buffer)) == null);
    try std.testing.expect(attachment.cell_deadline_ns != null);

    attachment.requestCellSnapshot();
    const frame = (try nextFrame(&fixture, attachment, &buffer)).?;
    try std.testing.expectEqual(@as(u64, 0), frame.base_frame_id);
    try expectLeadingText(frame, "recover");
    try std.testing.expect(!attachment.cells.snapshot_pending);
    try std.testing.expect(attachment.cell_deadline_ns == null);
}

test "pane EOF publishes deferred cells before its exit message" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    var buffer: [frame_buffer_size]u8 = undefined;
    try establishBaseline(&fixture, attachment, &buffer);
    deferPublication(attachment);
    _ = try fixture.pane.ingest(std.testing.io, "last");
    try std.testing.expect((try nextFrame(&fixture, attachment, &buffer)) == null);

    fixture.pane.output_done = true;
    fixture.pane.exit = .{ .exited = 0 };
    try std.testing.expect((try attachment.prepareExit(&buffer)) == null);
    const frame = (try nextFrame(&fixture, attachment, &buffer)).?;
    try expectLeadingText(frame, "last");
    try std.testing.expect((try attachment.prepareExit(&buffer)) == null);
    try acknowledge(attachment, frame);

    try std.testing.expect((try attachment.prepareExit(&buffer)) != null);
    try std.testing.expect(fixture.attachments.cellDeadline() == null);
}

test "input grants only its pane a bounded number of immediate publication frames" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const background_pane = try fixture.createPane(try core.pane(@intFromEnum(TestPane.background)));
    defer {
        background_pane.session.shutdown();
        background_pane.destroy();
    }

    var background = try Attachment.init(std.testing.allocator, background_pane);
    defer background.deinit();
    const target = fixture.attachments.find(fixture.pane.id).?;
    var target_buffer: [frame_buffer_size]u8 = undefined;
    var background_buffer: [frame_buffer_size]u8 = undefined;
    try establishBaseline(&fixture, target, &target_buffer);
    try establishBaseline(&fixture, &background, &background_buffer);
    deferPublication(target);
    deferPublication(&background);
    target.cell_pacer.input_grace = @intFromEnum(TestInterval.deferred);
    target.cell_pacer.input_frames = @intFromEnum(GraceBudget.limited);

    var capture: PaneInputTestScheduleCapture = .{ .expected_input = "x" };
    var handler: PaneInputHandler = .{
        .io = std.testing.io,
        .attachments = &fixture.attachments,
        .metrics = &fixture.metrics,
        .agent_input = null,
        .scheduler = capture.scheduler(),
    };
    _ = try handler.execute(.{ .pane_id = fixture.pane.id, .bytes = "x" });
    try std.testing.expect(fixture.pane.cell_input_ns != null);
    try std.testing.expect(background_pane.cell_input_ns == null);

    _ = try background_pane.ingest(std.testing.io, "flood");
    try std.testing.expect((try nextFrame(&fixture, &background, &background_buffer)) == null);
    const background_deadline = background.cell_deadline_ns.?;

    for (0..@intFromEnum(GraceBudget.limited)) |_| {
        _ = try fixture.pane.ingest(std.testing.io, "x");
        const frame = (try nextFrame(&fixture, target, &target_buffer)).?;
        try std.testing.expect(target.cell_deadline_ns == null);
        try acknowledge(target, frame);
    }

    try std.testing.expectEqual(@as(u32, 0), target.cell_pacer.input_frames_left);
    _ = try fixture.pane.ingest(std.testing.io, "z");
    try std.testing.expect((try nextFrame(&fixture, target, &target_buffer)) == null);
    try std.testing.expect(target.cell_deadline_ns != null);
    try std.testing.expect((try nextFrame(&fixture, &background, &background_buffer)) == null);
    try std.testing.expectEqual(background_deadline, background.cell_deadline_ns.?);
}

test "clients pace independently and an unacknowledged frame never advances its baseline" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const deferred = fixture.attachments.find(fixture.pane.id).?;
    var ready = try Attachment.init(std.testing.allocator, fixture.pane);
    defer ready.deinit();
    var deferred_buffer: [frame_buffer_size]u8 = undefined;
    var ready_buffer: [frame_buffer_size]u8 = undefined;
    try establishBaseline(&fixture, deferred, &deferred_buffer);
    try establishBaseline(&fixture, &ready, &ready_buffer);
    deferPublication(deferred);

    _ = try fixture.pane.ingest(std.testing.io, "start");
    try std.testing.expect((try nextFrame(&fixture, deferred, &deferred_buffer)) == null);
    const first = (try nextFrame(&fixture, &ready, &ready_buffer)).?;
    const first_revision = ready.observedCellRevision();

    _ = try fixture.pane.ingest(std.testing.io, "\x1b[Hfinal");
    try std.testing.expect((try nextFrame(&fixture, &ready, &ready_buffer)) == null);
    try std.testing.expectEqual(first_revision, ready.observedCellRevision());
    try std.testing.expectEqual(first.frame_id, ready.outstandingFrameId());
    try std.testing.expect((try nextFrame(&fixture, deferred, &deferred_buffer)) == null);
    try acknowledge(&ready, first);

    const latest = (try nextFrame(&fixture, &ready, &ready_buffer)).?;
    try std.testing.expectEqual(first.frame_id, latest.base_frame_id);
    try expectLeadingText(latest, "final");
    expirePublication(deferred);
    const folded = (try nextFrame(&fixture, deferred, &deferred_buffer)).?;
    try expectLeadingText(folded, "final");
    try std.testing.expect(folded.base_frame_id != latest.base_frame_id);
}

test "publication deadlines park during ingest and outstanding acknowledgement" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    var buffer: [frame_buffer_size]u8 = undefined;
    try establishBaseline(&fixture, attachment, &buffer);
    deferPublication(attachment);
    _ = try fixture.pane.ingest(std.testing.io, "pending");
    try std.testing.expect((try nextFrame(&fixture, attachment, &buffer)) == null);
    const deadline = fixture.attachments.cellDeadline().?;

    fixture.pane.ingest_pending = true;
    defer fixture.pane.ingest_pending = false;

    try std.testing.expect(fixture.attachments.cellDeadline() == null);
    try std.testing.expect((try nextFrame(&fixture, attachment, &buffer)) == null);
    try std.testing.expect(attachment.cell_deadline_ns == null);
    try std.testing.expect(fixture.pane.render_pending);
    fixture.pane.ingest_pending = false;

    try std.testing.expect((try nextFrame(&fixture, attachment, &buffer)) == null);
    try std.testing.expectEqual(deadline, fixture.attachments.cellDeadline().?);
    expirePublication(attachment);
    const frame = (try nextFrame(&fixture, attachment, &buffer)).?;
    attachment.cell_deadline_ns = deadline;
    try std.testing.expect(fixture.attachments.cellDeadline() == null);
    try std.testing.expect((try nextFrame(&fixture, attachment, &buffer)) == null);
    try std.testing.expect(attachment.cell_deadline_ns == null);
    try std.testing.expectEqual(frame.frame_id, attachment.outstandingFrameId());
    try acknowledge(attachment, frame);

    try std.testing.expect(fixture.attachments.cellDeadline() == null);
}

test "reattaching a deferred pane starts with a fresh publication budget and snapshot" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    var buffer: [frame_buffer_size]u8 = undefined;
    try establishBaseline(&fixture, attachment, &buffer);
    deferPublication(attachment);
    _ = try fixture.pane.ingest(std.testing.io, "reconnect");
    try std.testing.expect((try nextFrame(&fixture, attachment, &buffer)) == null);
    try std.testing.expect(fixture.attachments.cellDeadline() != null);

    try std.testing.expect(fixture.attachments.detach(fixture.pane.id) != null);
    try std.testing.expect(fixture.attachments.cellDeadline() == null);
    const reattached = try fixture.attachments.attach(std.testing.allocator, fixture.pane);
    try std.testing.expect(reattached.cell_deadline_ns == null);
    try std.testing.expect(reattached.cell_pacer.anchor_ns == null);
    const frame = (try nextFrame(&fixture, reattached, &buffer)).?;
    try std.testing.expectEqual(@as(u64, 0), frame.base_frame_id);
    try expectLeadingText(frame, "reconnect");
}

test "a deferred no-op projection clears its deadline without more output" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    var buffer: [frame_buffer_size]u8 = undefined;
    try establishBaseline(&fixture, attachment, &buffer);
    deferPublication(attachment);
    const observed = attachment.observedCellRevision();
    const next_frame_id = attachment.cells.next_frame_id;
    @memset(fixture.pane.damaged_rows, false);
    fixture.pane.dirty = false;

    _ = try fixture.pane.ingest(std.testing.io, "\x07");
    try std.testing.expect((try nextFrame(&fixture, attachment, &buffer)) == null);
    try std.testing.expect(fixture.attachments.cellDeadline() != null);
    try std.testing.expectEqual(observed, attachment.observedCellRevision());
    expirePublication(attachment);

    try std.testing.expect((try nextFrame(&fixture, attachment, &buffer)) == null);
    try std.testing.expectEqual(fixture.pane.cell_revision, attachment.observedCellRevision());
    try std.testing.expect(attachment.observedCellRevision() != observed);
    try std.testing.expect(!fixture.pane.render_pending);
    try std.testing.expect(!attachment.cells.hasOutstanding());
    try std.testing.expectEqual(next_frame_id, attachment.cells.next_frame_id);
    try std.testing.expect(fixture.attachments.cellDeadline() == null);
    try std.testing.expect((try nextFrame(&fixture, attachment, &buffer)) == null);
    try std.testing.expect(fixture.attachments.cellDeadline() == null);
}

test "successive no-op projections consume publication credit and defer further rendering" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    var buffer: [frame_buffer_size]u8 = undefined;
    try establishBaseline(&fixture, attachment, &buffer);
    attachment.cell_pacer = .{
        .interval = @intFromEnum(TestInterval.deferred),
        .burst = @intFromEnum(PreparationBudget.single),
        .credits = @intFromEnum(PreparationBudget.single),
        .anchor_ns = core.monotonic(std.testing.io),
    };
    @memset(fixture.pane.damaged_rows, false);
    fixture.pane.dirty = false;
    const initial_observed = attachment.observedCellRevision();
    const next_frame_id = attachment.cells.next_frame_id;
    const preparations = attachment.cell_pacer.stats.drawn;

    _ = try fixture.pane.ingest(std.testing.io, "\x07");
    try std.testing.expect((try nextFrame(&fixture, attachment, &buffer)) == null);
    try std.testing.expectEqual(@as(u64, @intFromEnum(PreparationBudget.single)), attachment.cell_pacer.stats.drawn - preparations);
    try std.testing.expectEqual(@as(u32, 0), attachment.cell_pacer.credits);
    try std.testing.expect(attachment.observedCellRevision() != initial_observed);
    try std.testing.expect(!fixture.pane.render_pending);
    try std.testing.expect(attachment.cell_deadline_ns == null);
    const observed_after_noop = attachment.observedCellRevision();
    const preparations_after_noop = attachment.cell_pacer.stats.drawn;

    _ = try fixture.pane.ingest(std.testing.io, "\x07");
    try std.testing.expect((try nextFrame(&fixture, attachment, &buffer)) == null);
    try std.testing.expect(fixture.pane.render_pending);
    try std.testing.expectEqual(observed_after_noop, attachment.observedCellRevision());
    try std.testing.expectEqual(preparations_after_noop, attachment.cell_pacer.stats.drawn);
    try std.testing.expect(fixture.attachments.cellDeadline() != null);
    try std.testing.expect(!attachment.cells.hasOutstanding());
    try std.testing.expectEqual(next_frame_id, attachment.cells.next_frame_id);

    expirePublication(attachment);
    try std.testing.expect((try nextFrame(&fixture, attachment, &buffer)) == null);
    try std.testing.expectEqual(@as(u64, @intFromEnum(PreparationBudget.single)), attachment.cell_pacer.stats.drawn - preparations_after_noop);
    try std.testing.expect(attachment.observedCellRevision() != observed_after_noop);
    try std.testing.expect(!fixture.pane.render_pending);
    try std.testing.expect(fixture.attachments.cellDeadline() == null);
}
