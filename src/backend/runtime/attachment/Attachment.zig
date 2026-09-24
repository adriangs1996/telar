const pacing = @import("pacing");
const core = @import("telar-core");
const Pane = @import("../../pane/Pane.zig");
const CellSync = @import("CellSync.zig");
const GraphicsSync = @import("GraphicsSync.zig");
const std = @import("std");
const Range = @import("Range.zig");
const selection = @import("selection.zig");
const attachment_namespace = @import("attachment_namespace.zig");
const ReviewContext = @import("../../change_review/Context.zig");
/// Per-client rendering state. It is disposable: reconnecting creates a fresh
/// baseline while the pane and its PTY continue to exist.
const Attachment = @This();

pub const GraphicsCounts = @import("GraphicsCounts.zig");
pub const CellPreparation = @import("CellPreparation.zig");
pub const GraphicsPreparation = @import("GraphicsPreparation.zig");
pub const Prepared = @import("Prepared.zig");

pub const CommitEffect = @import("CommitEffect.zig");
pane: *Pane,
cells: CellSync,
graphics: GraphicsSync,
cell_pacer: pacing.Pacer = .{},
cell_deadline_ns: ?u64 = null,
observed_cwd_revision: u64 = 0,
observed_foreground_revision: u64 = 0,
/// Starts at the empty-title revision so a fresh attachment learns only
/// titles a child actually set.
observed_title_revision: u64 = 1,
observed_progress_revision: u64 = 1,
observed_review_revision: u64 = 0,
exit_sent: bool = false,

pub fn init(gpa: std.mem.Allocator, pane: *Pane) !Attachment {
    return .{
        .pane = pane,
        .cells = try .init(gpa, pane),
        .graphics = .init(gpa, pane),
    };
}

pub fn deinit(self: *Attachment) void {
    self.cells.deinit(self.pane);
    if (self.graphics.shared_transport) {
        self.pane.noteSharedTransport(false);
    }
    self.graphics.deinit();
}

pub fn resizeIfNeeded(self: *Attachment) !bool {
    return self.cells.resizeIfNeeded(self.pane);
}

pub fn setViewport(self: *Attachment, requested: u32) !bool {
    return self.cells.setViewport(self.pane, requested);
}

pub fn requestCellSnapshot(self: *Attachment) void {
    self.cells.requestSnapshot();
}

pub fn copySelection(self: *Attachment, range: Range, scratch: []u8) selection.Result {
    return selection.extract(self.pane, range, scratch);
}

pub fn outstandingFrameId(self: *const Attachment) u64 {
    return self.cells.outstandingFrameId();
}

pub fn observedCellRevision(self: *const Attachment) u64 {
    return self.cells.observed_revision;
}

pub fn acknowledgeFrame(self: *Attachment, frame_id: u64, now_ns: u64) ?u64 {
    return self.cells.acknowledge(frame_id, now_ns);
}

pub fn prepareCwd(self: *Attachment, buffer: []u8) !?Prepared {
    const pane = self.pane;
    if (self.observed_cwd_revision == pane.cwd.revision) {
        return null;
    }
    return .{
        .bytes = try core.encodePaneCwd(buffer, .{
            .pane_id = pane.id,
            .cwd = pane.cwd.slice(),
        }),
        .effect = .{ .cwd = pane.cwd.revision },
    };
}

/// Replays retained review availability for each fresh attachment and coalesces live changes.
/// Example: `const prepared = try attachment.prepareReview(buffer);`.
pub fn prepareReview(self: *Attachment, buffer: []u8) !?Prepared {
    const availability = &self.pane.review_availability;
    if (self.observed_review_revision == availability.revision) {
        return null;
    }

    const change = availability.view() orelse return null;
    return .{ .bytes = try core.encodeChangeReviewChanged(buffer, change), .effect = .{ .review = availability.revision } };
}

test "review discovery replays on attach and reconnect without losing changes during send" {
    var pane: Pane = undefined;
    pane.review_availability = .{};
    const context = try ReviewContext.init(.{ .id = @enumFromInt(1), .generation = 4 }, .claude, "hook-session");
    var first: Attachment = undefined;
    first.pane = &pane;
    first.observed_review_revision = 0;
    var buffer: [1024]u8 = undefined;
    try std.testing.expect(try first.prepareReview(&buffer) == null);
    pane.review_availability.record(context, 2);
    const pending = (try first.prepareReview(&buffer)).?;
    const initial = (try core.decodeServer(pending.bytes)).change_review_changed;
    try std.testing.expectEqualStrings("hook-session", initial.session);
    try std.testing.expectEqual(@as(u64, 2), initial.latest_edition_id);
    pane.review_availability.record(context, 5);
    _ = first.commitPrepared(pending);
    const newer = (try first.prepareReview(&buffer)).?;
    try std.testing.expectEqual(@as(u64, 5), (try core.decodeServer(newer.bytes)).change_review_changed.latest_edition_id);
    _ = first.commitPrepared(newer);
    try std.testing.expect(try first.prepareReview(&buffer) == null);
    var reconnect: Attachment = undefined;
    reconnect.pane = &pane;
    reconnect.observed_review_revision = 0;
    const replayed = (try reconnect.prepareReview(&buffer)).?;
    try std.testing.expectEqual(@as(u64, 5), (try core.decodeServer(replayed.bytes)).change_review_changed.latest_edition_id);
    _ = reconnect.commitPrepared(replayed);
    pane.review_availability.invalidate();
    const cleared = (try first.prepareReview(&buffer)).?;
    try std.testing.expectEqual(@as(u64, 0), (try core.decodeServer(cleared.bytes)).change_review_changed.latest_edition_id);
    try std.testing.expect(try reconnect.prepareReview(&buffer) != null);
}

pub fn prepareTitle(self: *Attachment, buffer: []u8) !?Prepared {
    const pane = self.pane;
    if (self.observed_title_revision == pane.title.revision) {
        return null;
    }
    return .{
        .bytes = try core.encodePaneTitle(buffer, .{
            .pane_id = pane.id,
            .title = pane.title.slice(),
        }),
        .effect = .{ .title = pane.title.revision },
    };
}

pub fn prepareForeground(self: *Attachment, buffer: []u8) !?Prepared {
    const pane = self.pane;
    if (self.observed_foreground_revision == pane.foreground_revision) {
        return null;
    }
    return .{
        .bytes = try core.encodePaneForeground(buffer, .{
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
pub fn prepareProgress(self: *Attachment, buffer: []u8) !?Prepared {
    const pane = self.pane;
    if (self.observed_progress_revision == pane.progress_revision) {
        return null;
    }

    return .{
        .bytes = try core.encodePaneProgress(buffer, .{
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
pub fn prepareNextCells(self: *Attachment, preparation: CellPreparation) !?Prepared {
    const pane = self.pane;
    const scheduled_deadline = self.cell_deadline_ns;
    self.cell_deadline_ns = null;
    if (pane.ingest_pending) {
        return null;
    }

    if (self.cells.snapshot_pending) {
        const payload = (try self.cells.prepare(.{
            .io = preparation.io,
            .buffer = preparation.buffer,
            .pane = pane,
            .force_snapshot = true,
            .metrics = preparation.metrics,
        })) orelse
            return null;
        self.cells.snapshot_pending = false;
        return .{ .bytes = payload, .effect = .cells };
    }

    if (self.cells.hasOutstanding() or
        (!pane.render_pending and self.cells.observed_revision == pane.cell_revision))
    {
        return null;
    }

    const now_ns = pacing.clock.monotonic(preparation.io);
    if (pane.cell_input_ns) |input_ns| {
        if (self.cell_pacer.last_input_ns != input_ns) {
            self.cell_pacer.noteInput(input_ns);
        }
    }

    if (!pane.output_done) {
        if (self.cell_pacer.waitUntil(now_ns)) |deadline| {
            if (deadline > now_ns) {
                self.cell_deadline_ns = deadline;
                self.cell_pacer.noteThrottled();
                return null;
            }
        }
    }

    const payload = try self.cells.prepare(.{
        .io = preparation.io,
        .buffer = preparation.buffer,
        .pane = pane,
        .force_snapshot = false,
        .metrics = preparation.metrics,
    });
    if (pane.render_pending or self.cells.observed_revision != pane.cell_revision) {
        return null;
    }

    // A no-op still paid for projection and diff; synchronized holds did not.
    self.cell_pacer.record(.{
        .now = now_ns,
        .scheduled_deadline = if (scheduled_deadline) |deadline| (if (now_ns >= deadline) deadline else null) else null,
        .absorbed = 1,
    });

    return if (payload) |bytes| .{ .bytes = bytes, .effect = .cells } else null;
}

pub fn prepareExit(self: *Attachment, buffer: []u8) !?Prepared {
    const pane = self.pane;
    if (pane.ingest_pending or self.exit_sent or !pane.output_done or
        pane.exit == null or self.outstandingFrameId() != 0 or
        self.cells.snapshot_pending or pane.render_pending or
        self.cells.observed_revision != pane.cell_revision)
    {
        return null;
    }
    const exit = pane.exit.?;
    return .{
        .bytes = try core.encodePaneExited(buffer, .{
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

pub fn requestGraphicsSnapshot(self: *Attachment) void {
    self.graphics.reset();
}

pub fn configureGraphics(self: *Attachment, shared: bool) void {
    if (self.graphics.shared_transport == shared) {
        return;
    }
    self.graphics.shared_transport = shared;
    self.pane.noteSharedTransport(shared);
}

pub fn returnGraphicsCredit(self: *Attachment, bytes: usize) bool {
    const available = core.max_image_bytes_per_pane -| self.graphics.credit;
    if (bytes == 0 or bytes > available) {
        return false;
    }

    self.graphics.credit += bytes;
    return true;
}

pub fn graphicsCredit(self: *const Attachment) usize {
    return self.graphics.credit;
}

pub fn hasFrozenGraphics(self: *const Attachment) bool {
    return self.graphics.transfer != null;
}

pub fn hasGraphicsWork(self: *const Attachment) bool {
    return self.graphics.snapshot != .idle or
        self.graphics.transfer != null or
        self.graphics.observed_revision != self.pane.graphics_revision;
}

/// Prepares one bounded graphics message using the currently available
/// client and global transport credit.
///
/// ```zig
/// const prepared = try attachment.prepareNextGraphics(.{ .buffer = buffer, .global_credit = credit, .live_storage_available = true });
/// ```
pub fn prepareNextGraphics(self: *Attachment, preparation: GraphicsPreparation) !?Prepared {
    const payload = (try attachment_namespace.encodeNextGraphics(self, preparation)) orelse return null;

    return .{
        .bytes = payload,
        .effect = .{ .graphics = self.takeGraphicsCounts() },
    };
}

pub fn abandonGraphics(self: *Attachment) void {
    attachment_namespace.abandonGraphicsBatch(self);
}

pub fn takeGraphicsCounts(self: *Attachment) GraphicsCounts {
    const result: GraphicsCounts = .{
        .images = self.graphics.sent_images,
        .placements = self.graphics.sent_placements,
        .stage_blocked = self.graphics.stage_blocked,
        .adopted = self.graphics.adopted,
        .freeze = self.graphics.freeze,
    };
    self.graphics.sent_images = 0;
    self.graphics.sent_placements = 0;
    self.graphics.stage_blocked = 0;
    self.graphics.adopted = 0;
    self.graphics.freeze = .{};
    return result;
}

pub fn stageGraphics(self: *Attachment, global_credit: usize) !attachment_namespace.StageResult {
    return attachment_namespace.stageNextTransfer(self, global_credit);
}

pub fn graphicsCaughtUp(self: *const Attachment) bool {
    return !self.graphics.batch_active and
        self.graphics.observed_revision == self.pane.graphics_revision;
}

pub fn graphicsTransferBytes(self: *const Attachment) usize {
    return if (self.graphics.transfer) |transfer| transfer.reserved_len else 0;
}

pub fn commitPrepared(self: *Attachment, prepared: Prepared) CommitEffect {
    return switch (prepared.effect) {
        .cwd => |revision| effect: {
            self.observed_cwd_revision = revision;
            break :effect .{};
        },
        .foreground => |revision| effect: {
            self.observed_foreground_revision = revision;
            break :effect .{};
        },
        .title => |revision| effect: {
            self.observed_title_revision = revision;
            break :effect .{};
        },
        .progress => |revision| effect: {
            self.observed_progress_revision = revision;
            break :effect .{};
        },
        .review => |revision| effect: {
            self.observed_review_revision = revision;
            break :effect .{};
        },
        .cells => .{},
        .exit => effect: {
            self.exit_sent = true;
            break :effect .{ .detach_after_send = self.pane.id };
        },
        .graphics => |counts| .{ .graphics_message = true, .graphics = counts },
    };
}

pub fn freeTransfer(self: *Attachment) void {
    self.graphics.freeTransfer();
}
