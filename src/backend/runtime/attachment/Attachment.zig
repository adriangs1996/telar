/// Per-client rendering state. It is disposable: reconnecting creates a fresh
/// baseline while the pane and its PTY continue to exist.
const Attachment = @This();
const core = @import("telar-core");
const source_namespace = @import("root.zig");
const telemetry = @import("../observability/root.zig").telemetry;
const cell = @import("cell.zig");
const graphics_module = @import("graphics.zig");
const std = @import("std");
const selection = @import("selection.zig");
pub const GraphicsCounts = struct {
    images: u32,
    placements: u32,
    /// Freezes refused because the next image exceeded the client's or
    /// the runtime's memory credit.
    stage_blocked: u32,
    /// Transfers adopted from objects the media actor froze.
    adopted: u32,
    /// Time spent copying frozen generations out of live media storage
    /// on the runtime thread, the fallback when nothing was adopted.
    freeze: core.diagnostics.Timing,
};
pub const CellPreparation = struct {
    io: source_namespace.Io,
    buffer: []u8,
    metrics: *telemetry.RuntimeMetrics,
};
pub const GraphicsPreparation = struct {
    buffer: []u8,
    global_credit: usize,
    live_storage_available: bool,
};
pub const Prepared = struct {
    bytes: []const u8,
    effect: Effect,

    const Effect = union(enum) {
        cwd: u64,
        foreground: u64,
        title: u64,
        progress: u64,
        cells,
        exit,
        graphics: GraphicsCounts,
    };
};

pub const CommitEffect = struct {
    detach_after_send: ?source_namespace.schema.PaneId = null,
    graphics_message: bool = false,
    graphics: GraphicsCounts = .{ .images = 0, .placements = 0, .stage_blocked = 0, .adopted = 0, .freeze = .{} },
};
pane: *source_namespace.Pane,
cells: cell.Sync,
graphics: graphics_module.Sync,
observed_cwd_revision: u64 = 0,
observed_foreground_revision: u64 = 0,
/// Starts at the empty-title revision so a fresh attachment learns only
/// titles a child actually set.
observed_title_revision: u64 = 1,
observed_progress_revision: u64 = 1,
exit_sent: bool = false,

pub fn init(gpa: std.mem.Allocator, pane: *source_namespace.Pane) !Attachment {
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

pub fn copySelection(attachment: *Attachment, range: selection.Range, scratch: []u8) selection.Result {
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

pub fn prepareCwd(attachment: *Attachment, buffer: []u8) !?Prepared {
    const pane = attachment.pane;
    if (attachment.observed_cwd_revision == pane.cwd.revision) {
        return null;
    }
    return .{
        .bytes = try source_namespace.schema.encodePaneCwd(buffer, .{
            .pane_id = pane.id,
            .cwd = pane.cwd.slice(),
        }),
        .effect = .{ .cwd = pane.cwd.revision },
    };
}

pub fn prepareTitle(attachment: *Attachment, buffer: []u8) !?Prepared {
    const pane = attachment.pane;
    if (attachment.observed_title_revision == pane.title.revision) {
        return null;
    }
    return .{
        .bytes = try source_namespace.schema.encodePaneTitle(buffer, .{
            .pane_id = pane.id,
            .title = pane.title.slice(),
        }),
        .effect = .{ .title = pane.title.revision },
    };
}

pub fn prepareForeground(attachment: *Attachment, buffer: []u8) !?Prepared {
    const pane = attachment.pane;
    if (attachment.observed_foreground_revision == pane.foreground_revision) {
        return null;
    }
    return .{
        .bytes = try source_namespace.schema.encodePaneForeground(buffer, .{
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
pub fn prepareProgress(attachment: *Attachment, buffer: []u8) !?Prepared {
    const pane = attachment.pane;
    if (attachment.observed_progress_revision == pane.progress_revision) {
        return null;
    }

    return .{
        .bytes = try source_namespace.schema.encodePaneProgress(buffer, .{
            .pane_id = pane.id,
            .state = pane.progress_state,
            .percent = pane.progress_percent,
        }),
        .effect = .{ .progress = pane.progress_revision },
    };
}

/// Prepares one snapshot or incremental cell frame while preserving the
/// outstanding-frame and ingest single-flight rules.
///
/// ```zig
/// const prepared = try attachment.prepareNextCells(.{ .io = io, .buffer = buffer, .metrics = metrics });
/// ```
pub fn prepareNextCells(attachment: *Attachment, preparation: CellPreparation) !?Prepared {
    const pane = attachment.pane;
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
            unreachable;
        attachment.cells.snapshot_pending = false;
        return .{ .bytes = payload, .effect = .cells };
    }

    if (attachment.cells.hasOutstanding() or
        (!pane.render_pending and attachment.cells.observed_revision == pane.cell_revision))
    {
        return null;
    }

    const payload = (try attachment.cells.prepare(.{
        .io = preparation.io,
        .buffer = preparation.buffer,
        .pane = pane,
        .force_snapshot = false,
        .metrics = preparation.metrics,
    })) orelse
        return null;

    return .{ .bytes = payload, .effect = .cells };
}

pub fn prepareExit(attachment: *Attachment, buffer: []u8) !?Prepared {
    const pane = attachment.pane;
    if (pane.ingest_pending or attachment.exit_sent or !pane.output_done or
        pane.exit == null or attachment.outstandingFrameId() != 0)
    {
        return null;
    }
    const exit = pane.exit.?;
    return .{
        .bytes = try source_namespace.schema.encodePaneExited(buffer, .{
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
    const available = core.graphics.max_image_bytes_per_pane -| attachment.graphics.credit;
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
pub fn prepareNextGraphics(attachment: *Attachment, preparation: GraphicsPreparation) !?Prepared {
    const payload = (try source_namespace.encodeNextGraphics(attachment, preparation)) orelse return null;

    return .{
        .bytes = payload,
        .effect = .{ .graphics = attachment.takeGraphicsCounts() },
    };
}

pub fn abandonGraphics(attachment: *Attachment) void {
    source_namespace.abandonGraphicsBatch(attachment);
}

pub fn takeGraphicsCounts(attachment: *Attachment) GraphicsCounts {
    const result: GraphicsCounts = .{
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

pub fn stageGraphics(attachment: *Attachment, global_credit: usize) !source_namespace.StageResult {
    return source_namespace.stageNextTransfer(attachment, global_credit);
}

pub fn graphicsCaughtUp(attachment: *const Attachment) bool {
    return !attachment.graphics.batch_active and
        attachment.graphics.observed_revision == attachment.pane.graphics_revision;
}

pub fn graphicsTransferBytes(attachment: *const Attachment) usize {
    return if (attachment.graphics.transfer) |transfer| transfer.reserved_len else 0;
}

pub fn commitPrepared(attachment: *Attachment, prepared: Prepared) CommitEffect {
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
