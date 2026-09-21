const GraphicsCountsType = @import("GraphicsCounts.zig");
const CellPreparationType = @import("CellPreparation.zig");
const GraphicsPreparationType = @import("GraphicsPreparation.zig");
const PreparedType = @import("Prepared.zig");
const CommitEffectType = @import("CommitEffect.zig");
const PaneType = @import("../../pane/Pane.zig");
const CellSync = @import("CellSync.zig");
const GraphicsSync = @import("GraphicsSync.zig");
const std = @import("std");
const RangeType = @import("Range.zig");
const selection = @import("selection.zig");
const encodePaneCwd_module = @import("telar-core").encodePaneCwd;
const encodePaneTitle_module = @import("telar-core").encodePaneTitle;
const encodePaneForeground_module = @import("telar-core").encodePaneForeground;
const encodePaneProgress_module = @import("telar-core").encodePaneProgress;
const encodePaneExited_module = @import("telar-core").encodePaneExited;
const max_image_bytes_per_pane_module = @import("telar-core").max_image_bytes_per_pane;
const attachment_namespace = @import("attachment_namespace.zig");
const Pacer = @import("telar-core").Pacer;
const monotonic = @import("telar-core").monotonic;
const encodeChangeReviewChanged = @import("telar-core").encodeChangeReviewChanged;
const ReviewContext = @import("../../change_review/Context.zig");
const decodeServer = @import("telar-core").decodeServer;
/// Per-client rendering state. It is disposable: reconnecting creates a fresh
/// baseline while the pane and its PTY continue to exist.
const Attachment = @This();

pub const GraphicsCounts = @import("GraphicsCounts.zig");
pub const CellPreparation = @import("CellPreparation.zig");
pub const GraphicsPreparation = @import("GraphicsPreparation.zig");
pub const Prepared = @import("Prepared.zig");

pub const CommitEffect = @import("CommitEffect.zig");
pane: *PaneType,
cells: CellSync,
graphics: GraphicsSync,
cell_pacer: Pacer = .{},
cell_deadline_ns: ?u64 = null,
observed_cwd_revision: u64 = 0,
observed_foreground_revision: u64 = 0,
/// Starts at the empty-title revision so a fresh attachment learns only
/// titles a child actually set.
observed_title_revision: u64 = 1,
observed_progress_revision: u64 = 1,
observed_review_revision: u64 = 0,
exit_sent: bool = false,

pub fn init(gpa: std.mem.Allocator, pane: *PaneType) !Attachment {
    return .{
        .pane = pane,
        .cells = try .init(gpa, pane),
        .graphics = .init(gpa, pane),
    };
}

pub fn deinit(attachment: *Attachment) void {
    attachment.cells.deinit(attachment.pane);
    if (attachment.graphics.shared_transport) {
        attachment.pane.noteSharedTransport(false);
    }
    attachment.graphics.deinit();
}

pub fn resizeIfNeeded(attachment: *Attachment) !bool {
    return attachment.cells.resizeIfNeeded(attachment.pane);
}

pub fn setViewport(attachment: *Attachment, requested: u32) !bool {
    return attachment.cells.setViewport(attachment.pane, requested);
}

pub fn requestCellSnapshot(attachment: *Attachment) void {
    attachment.cells.requestSnapshot();
}

pub fn copySelection(attachment: *Attachment, range: RangeType, scratch: []u8) selection.Result {
    return selection.extract(attachment.pane, range, scratch);
}

pub fn outstandingFrameId(attachment: *const Attachment) u64 {
    return attachment.cells.outstandingFrameId();
}

pub fn observedCellRevision(attachment: *const Attachment) u64 {
    return attachment.cells.observed_revision;
}

pub fn acknowledgeFrame(attachment: *Attachment, frame_id: u64, now_ns: u64) ?u64 {
    return attachment.cells.acknowledge(frame_id, now_ns);
}

pub fn prepareCwd(attachment: *Attachment, buffer: []u8) !?PreparedType {
    const pane = attachment.pane;
    if (attachment.observed_cwd_revision == pane.cwd.revision) {
        return null;
    }
    return .{
        .bytes = try encodePaneCwd_module(buffer, .{
            .pane_id = pane.id,
            .cwd = pane.cwd.slice(),
        }),
        .effect = .{ .cwd = pane.cwd.revision },
    };
}

/// Replays retained review availability for each fresh attachment and coalesces live changes.
/// Example: `const prepared = try attachment.prepareReview(buffer);`.
pub fn prepareReview(self: *Attachment, buffer: []u8) !?PreparedType {
    const availability = &self.pane.review_availability;
    if (self.observed_review_revision == availability.revision) {
        return null;
    }

    const change = availability.view() orelse return null;
    return .{ .bytes = try encodeChangeReviewChanged(buffer, change), .effect = .{ .review = availability.revision } };
}

test "review discovery replays on attach and reconnect without losing changes during send" {
    var pane: PaneType = undefined;
    pane.review_availability = .{};
    const context = try ReviewContext.init(.{ .id = @enumFromInt(1), .generation = 4 }, .claude, "hook-session");
    var first: Attachment = undefined;
    first.pane = &pane;
    first.observed_review_revision = 0;
    var buffer: [1024]u8 = undefined;
    try std.testing.expect(try first.prepareReview(&buffer) == null);
    pane.review_availability.record(context, 2);
    const pending = (try first.prepareReview(&buffer)).?;
    const initial = (try decodeServer(pending.bytes)).change_review_changed;
    try std.testing.expectEqualStrings("hook-session", initial.session);
    try std.testing.expectEqual(@as(u64, 2), initial.latest_edition_id);
    pane.review_availability.record(context, 5);
    _ = first.commitPrepared(pending);
    const newer = (try first.prepareReview(&buffer)).?;
    try std.testing.expectEqual(@as(u64, 5), (try decodeServer(newer.bytes)).change_review_changed.latest_edition_id);
    _ = first.commitPrepared(newer);
    try std.testing.expect(try first.prepareReview(&buffer) == null);
    var reconnect: Attachment = undefined;
    reconnect.pane = &pane;
    reconnect.observed_review_revision = 0;
    const replayed = (try reconnect.prepareReview(&buffer)).?;
    try std.testing.expectEqual(@as(u64, 5), (try decodeServer(replayed.bytes)).change_review_changed.latest_edition_id);
    _ = reconnect.commitPrepared(replayed);
    pane.review_availability.invalidate();
    const cleared = (try first.prepareReview(&buffer)).?;
    try std.testing.expectEqual(@as(u64, 0), (try decodeServer(cleared.bytes)).change_review_changed.latest_edition_id);
    try std.testing.expect(try reconnect.prepareReview(&buffer) != null);
}

pub fn prepareTitle(attachment: *Attachment, buffer: []u8) !?PreparedType {
    const pane = attachment.pane;
    if (attachment.observed_title_revision == pane.title.revision) {
        return null;
    }
    return .{
        .bytes = try encodePaneTitle_module(buffer, .{
            .pane_id = pane.id,
            .title = pane.title.slice(),
        }),
        .effect = .{ .title = pane.title.revision },
    };
}

pub fn prepareForeground(attachment: *Attachment, buffer: []u8) !?PreparedType {
    const pane = attachment.pane;
    if (attachment.observed_foreground_revision == pane.foreground_revision) {
        return null;
    }
    return .{
        .bytes = try encodePaneForeground_module(buffer, .{
            .pane_id = pane.id,
            .name = pane.agent_process_cache.name(),
        }),
        .effect = .{ .foreground = pane.foreground_revision },
    };
}

/// Prepares the newest coalesced progress state for this client attachment.
///
/// ```zig
/// const prepared = try attachment.prepareProgress(buffer);
/// ```
pub fn prepareProgress(attachment: *Attachment, buffer: []u8) !?PreparedType {
    const pane = attachment.pane;
    if (attachment.observed_progress_revision == pane.progress_revision) {
        return null;
    }

    return .{
        .bytes = try encodePaneProgress_module(buffer, .{
            .pane_id = pane.id,
            .state = pane.progress_state,
            .percent = pane.progress_percent,
        }),
        .effect = .{ .progress = pane.progress_revision },
    };
}

/// Prepares one snapshot or incremental cell frame while preserving the
/// outstanding-frame and ingest single-flight rules. A snapshot deferred
/// by synchronized output remains pending for the next delivery attempt.
///
/// ```zig
/// const prepared = try attachment.prepareNextCells(.{ .io = io, .buffer = buffer, .metrics = metrics });
/// ```
pub fn prepareNextCells(attachment: *Attachment, preparation: CellPreparationType) !?PreparedType {
    const pane = attachment.pane;
    const scheduled_deadline = attachment.cell_deadline_ns;
    attachment.cell_deadline_ns = null;
    if (pane.ingest_pending) {
        return null;
    }

    if (attachment.cells.snapshot_pending) {
        const payload = (try attachment.cells.prepare(.{
            .io = preparation.io,
            .buffer = preparation.buffer,
            .pane = pane,
            .force_snapshot = true,
            .metrics = preparation.metrics,
        })) orelse
            return null;
        attachment.cells.snapshot_pending = false;
        return .{ .bytes = payload, .effect = .cells };
    }

    if (attachment.cells.hasOutstanding() or
        (!pane.render_pending and attachment.cells.observed_revision == pane.cell_revision))
    {
        return null;
    }

    const now_ns = monotonic(preparation.io);
    if (pane.cell_input_ns) |input_ns| {
        if (attachment.cell_pacer.last_input_ns != input_ns) {
            attachment.cell_pacer.noteInput(input_ns);
        }
    }

    if (!pane.output_done) {
        if (attachment.cell_pacer.waitUntil(now_ns)) |deadline| {
            if (deadline > now_ns) {
                attachment.cell_deadline_ns = deadline;
                attachment.cell_pacer.noteThrottled();
                return null;
            }
        }
    }

    const payload = try attachment.cells.prepare(.{
        .io = preparation.io,
        .buffer = preparation.buffer,
        .pane = pane,
        .force_snapshot = false,
        .metrics = preparation.metrics,
    });
    if (pane.render_pending or attachment.cells.observed_revision != pane.cell_revision) {
        return null;
    }

    // A no-op still paid for projection and diff; synchronized holds did not.
    attachment.cell_pacer.record(.{
        .now = now_ns,
        .scheduled_deadline = if (scheduled_deadline) |deadline| (if (now_ns >= deadline) deadline else null) else null,
        .absorbed = 1,
    });

    return if (payload) |bytes| .{ .bytes = bytes, .effect = .cells } else null;
}

pub fn prepareExit(attachment: *Attachment, buffer: []u8) !?PreparedType {
    const pane = attachment.pane;
    if (pane.ingest_pending or attachment.exit_sent or !pane.output_done or
        pane.exit == null or attachment.outstandingFrameId() != 0 or
        attachment.cells.snapshot_pending or pane.render_pending or
        attachment.cells.observed_revision != pane.cell_revision)
    {
        return null;
    }
    const exit = pane.exit.?;
    return .{
        .bytes = try encodePaneExited_module(buffer, .{
            .pane_id = pane.id,
            .kind = switch (exit) {
                .exited => .exited,
                .signaled => .signaled,
            },
            .value = switch (exit) {
                .exited => |status| status,
                .signaled => |signal| @intFromEnum(signal),
            },
        }),
        .effect = .exit,
    };
}

pub fn requestGraphicsSnapshot(attachment: *Attachment) void {
    attachment.graphics.reset();
}

pub fn configureGraphics(attachment: *Attachment, shared: bool) void {
    if (attachment.graphics.shared_transport == shared) {
        return;
    }
    attachment.graphics.shared_transport = shared;
    attachment.pane.noteSharedTransport(shared);
}

pub fn returnGraphicsCredit(attachment: *Attachment, bytes: usize) bool {
    const available = max_image_bytes_per_pane_module -| attachment.graphics.credit;
    if (bytes == 0 or bytes > available) {
        return false;
    }

    attachment.graphics.credit += bytes;
    return true;
}

pub fn graphicsCredit(attachment: *const Attachment) usize {
    return attachment.graphics.credit;
}

pub fn hasFrozenGraphics(attachment: *const Attachment) bool {
    return attachment.graphics.transfer != null;
}

pub fn hasGraphicsWork(attachment: *const Attachment) bool {
    return attachment.graphics.snapshot != .idle or
        attachment.graphics.transfer != null or
        attachment.graphics.observed_revision != attachment.pane.graphics_revision;
}

/// Prepares one bounded graphics message using the currently available
/// client and global transport credit.
///
/// ```zig
/// const prepared = try attachment.prepareNextGraphics(.{ .buffer = buffer, .global_credit = credit, .live_storage_available = true });
/// ```
pub fn prepareNextGraphics(attachment: *Attachment, preparation: GraphicsPreparationType) !?PreparedType {
    const payload = (try attachment_namespace.encodeNextGraphics(attachment, preparation)) orelse return null;

    return .{
        .bytes = payload,
        .effect = .{ .graphics = attachment.takeGraphicsCounts() },
    };
}

pub fn abandonGraphics(attachment: *Attachment) void {
    attachment_namespace.abandonGraphicsBatch(attachment);
}

pub fn takeGraphicsCounts(attachment: *Attachment) GraphicsCountsType {
    const result: GraphicsCountsType = .{
        .images = attachment.graphics.sent_images,
        .placements = attachment.graphics.sent_placements,
        .stage_blocked = attachment.graphics.stage_blocked,
        .adopted = attachment.graphics.adopted,
        .freeze = attachment.graphics.freeze,
    };
    attachment.graphics.sent_images = 0;
    attachment.graphics.sent_placements = 0;
    attachment.graphics.stage_blocked = 0;
    attachment.graphics.adopted = 0;
    attachment.graphics.freeze = .{};
    return result;
}

pub fn stageGraphics(attachment: *Attachment, global_credit: usize) !attachment_namespace.StageResult {
    return attachment_namespace.stageNextTransfer(attachment, global_credit);
}

pub fn graphicsCaughtUp(attachment: *const Attachment) bool {
    return !attachment.graphics.batch_active and
        attachment.graphics.observed_revision == attachment.pane.graphics_revision;
}

pub fn graphicsTransferBytes(attachment: *const Attachment) usize {
    return if (attachment.graphics.transfer) |transfer| transfer.reserved_len else 0;
}

pub fn commitPrepared(attachment: *Attachment, prepared: PreparedType) CommitEffectType {
    return switch (prepared.effect) {
        .cwd => |revision| effect: {
            attachment.observed_cwd_revision = revision;
            break :effect .{};
        },
        .foreground => |revision| effect: {
            attachment.observed_foreground_revision = revision;
            break :effect .{};
        },
        .title => |revision| effect: {
            attachment.observed_title_revision = revision;
            break :effect .{};
        },
        .progress => |revision| effect: {
            attachment.observed_progress_revision = revision;
            break :effect .{};
        },
        .review => |revision| effect: {
            attachment.observed_review_revision = revision;
            break :effect .{};
        },
        .cells => .{},
        .exit => effect: {
            attachment.exit_sent = true;
            break :effect .{ .detach_after_send = attachment.pane.id };
        },
        .graphics => |counts| .{ .graphics_message = true, .graphics = counts },
    };
}

pub fn freeTransfer(attachment: *Attachment) void {
    attachment.graphics.freeTransfer();
}
