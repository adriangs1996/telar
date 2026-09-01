//! Per-client synchronization of one runtime-owned pane.
//!
//! `Attachment` is the supported seam. Cell projection and graphics transfer
//! remain private synchronization modules with independent state and budgets.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const history = @import("../../history/root.zig");
const pane_mod = @import("../../pane/root.zig");
const media_mod = @import("../../media/root.zig");
const pty = @import("../../pty/root.zig");
const cell = @import("cell.zig");
const graphics = @import("graphics.zig");
const selection = @import("selection.zig");
const telemetry = @import("../observability/root.zig").telemetry;

const Io = std.Io;
const schema = core.schema;
const GraphicsBudget = pane_mod.GraphicsBudget;
const Pane = pane_mod.Pane;
const SlotIndex = pane_mod.SlotIndex;
const max_panes = pane_mod.max_panes;

pub fn initSharedFreezeNonce(io: Io) void {
    graphics.initSharedFreezeNonce(io);
}

/// Per-client rendering state. It is disposable: reconnecting creates a fresh
/// baseline while the pane and its PTY continue to exist.
pub const Attachment = struct {
    pub const GraphicsCounts = struct { images: u32, placements: u32 };
    pub const CellPreparation = struct {
        io: Io,
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
            cells,
            exit,
            graphics: GraphicsCounts,
        };
    };

    pub const CommitEffect = struct {
        detach_after_send: ?schema.PaneId = null,
        graphics_message: bool = false,
        graphics: GraphicsCounts = .{ .images = 0, .placements = 0 },
    };
    pane: *Pane,
    cells: cell.Sync,
    graphics: graphics.Sync,
    observed_cwd_revision: u64 = 0,
    observed_foreground_revision: u64 = 0,
    exit_sent: bool = false,

    pub fn init(gpa: std.mem.Allocator, pane: *Pane) !Attachment {
        return .{
            .pane = pane,
            .cells = try .init(gpa, pane),
            .graphics = .init(gpa, pane),
        };
    }

    pub fn deinit(attachment: *Attachment) void {
        attachment.cells.deinit(attachment.pane);
        attachment.graphics.deinit();
    }

    pub fn resizeIfNeeded(attachment: *Attachment) !bool {
        return attachment.cells.resizeIfNeeded(attachment.pane);
    }

    fn setViewport(attachment: *Attachment, requested: u32) !bool {
        return attachment.cells.setViewport(attachment.pane, requested);
    }

    fn requestCellSnapshot(attachment: *Attachment) void {
        attachment.cells.requestSnapshot();
    }

    fn copySelection(attachment: *Attachment, range: selection.Range, scratch: []u8) selection.Result {
        return selection.extract(attachment.pane, range, scratch);
    }

    pub fn outstandingFrameId(attachment: *const Attachment) u64 {
        return attachment.cells.outstandingFrameId();
    }

    pub fn observedCellRevision(attachment: *const Attachment) u64 {
        return attachment.cells.observed_revision;
    }

    fn acknowledgeFrame(attachment: *Attachment, frame_id: u64, now_ns: u64) ?u64 {
        return attachment.cells.acknowledge(frame_id, now_ns);
    }

    pub fn prepareCwd(attachment: *Attachment, buffer: []u8) !?Prepared {
        const pane = attachment.pane;
        if (attachment.observed_cwd_revision == pane.cwd.revision) return null;
        return .{
            .bytes = try schema.encodePaneCwd(buffer, .{
                .pane_id = pane.id,
                .cwd = pane.cwd.slice(),
            }),
            .effect = .{ .cwd = pane.cwd.revision },
        };
    }

    pub fn prepareForeground(attachment: *Attachment, buffer: []u8) !?Prepared {
        const pane = attachment.pane;
        if (attachment.observed_foreground_revision == pane.foreground_revision) return null;
        return .{
            .bytes = try schema.encodePaneForeground(buffer, .{
                .pane_id = pane.id,
                .name = pane.agent_process_cache.name(),
            }),
            .effect = .{ .foreground = pane.foreground_revision },
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
            pane.exit == null or attachment.outstandingFrameId() != 0) return null;
        const exit = pane.exit.?;
        return .{
            .bytes = try schema.encodePaneExited(buffer, .{
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

    fn requestGraphicsSnapshot(attachment: *Attachment) void {
        attachment.graphics.reset();
    }

    fn configureGraphics(attachment: *Attachment, shared: bool) void {
        attachment.graphics.shared_transport = shared;
    }

    fn returnGraphicsCredit(attachment: *Attachment, bytes: usize) bool {
        const available = core.graphics.max_image_bytes_per_pane -| attachment.graphics.credit;
        if (bytes == 0 or bytes > available) {
            return false;
        }

        attachment.graphics.credit += bytes;
        return true;
    }

    fn graphicsCredit(attachment: *const Attachment) usize {
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
        const payload = (try encodeNextGraphics(attachment, preparation)) orelse return null;

        return .{
            .bytes = payload,
            .effect = .{ .graphics = attachment.takeGraphicsCounts() },
        };
    }

    pub fn abandonGraphics(attachment: *Attachment) void {
        abandonGraphicsBatch(attachment);
    }

    pub fn takeGraphicsCounts(attachment: *Attachment) GraphicsCounts {
        const result: GraphicsCounts = .{
            .images = attachment.graphics.sent_images,
            .placements = attachment.graphics.sent_placements,
        };
        attachment.graphics.sent_images = 0;
        attachment.graphics.sent_placements = 0;
        return result;
    }

    pub fn stageGraphics(attachment: *Attachment, global_credit: usize) !StageResult {
        return stageNextTransfer(attachment, global_credit);
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
};

/// Committed removal of one pane from a client's disposable view state.
pub const PaneDetached = struct {
    pane_id: schema.PaneId,
    workspace: schema.WorkspaceLocation,
    last_attachment: bool,
};

pub const ViewportUpdate = enum {
    changed,
    unchanged,
};

pub const GraphicsCreditUpdate = enum {
    returned,
    pane_not_attached,
    invalid_amount,
};

pub const GraphicsConfigurationUpdate = enum {
    changed,
    unchanged,
};

pub const SelectionRange = selection.Range;
pub const SelectionResult = selection.Result;
pub const selection_scratch_bytes = selection.scratch_bytes;
pub const SelectionQuery = struct {
    range: SelectionRange,
    scratch: []u8,
};

pub const AttachmentStore = struct {
    pub const capacity = max_panes;
    pub const Iterator = struct {
        store: *const AttachmentStore,
        position: usize = 0,

        pub fn next(self: *Iterator) ?*const Attachment {
            while (self.position < self.store.items.len) {
                defer self.position += 1;
                if (self.store.items[self.position]) |*value| return value;
            }
            return null;
        }
    };

    items: [max_panes]?Attachment = [_]?Attachment{null} ** max_panes,
    count: usize = 0,
    index: SlotIndex(2 * max_panes) = .{},
    workspace: ?schema.WorkspaceLocation = null,
    shared_graphics: bool = false,

    pub fn find(store: *AttachmentStore, pane_id: schema.PaneId) ?*Attachment {
        const slot = store.index.get(schema.id.raw(pane_id)) orelse return null;
        const attachment = &store.items[slot].?;
        std.debug.assert(attachment.pane.id == pane_id);
        return attachment;
    }

    /// Coalesces a full cell-snapshot request into the selected client
    /// attachment. Missing panes leave every attachment unchanged.
    ///
    /// ```zig
    /// if (!store.requestCellSnapshot(pane_id)) {
    ///     recordStaleMessage();
    /// }
    /// ```
    pub fn requestCellSnapshot(store: *AttachmentStore, pane_id: schema.PaneId) bool {
        const attachment = store.find(pane_id) orelse return false;
        attachment.requestCellSnapshot();
        return true;
    }

    /// Replaces one client's graphics baseline with a complete snapshot. Any
    /// frozen transfer is released before the recovery mark becomes visible;
    /// repeated requests coalesce and retain transport policy and credit.
    ///
    /// ```zig
    /// if (!store.requestGraphicsSnapshot(pane_id)) {
    ///     recordStaleMessage();
    /// }
    /// ```
    pub fn requestGraphicsSnapshot(store: *AttachmentStore, pane_id: schema.PaneId) bool {
        const attachment = store.find(pane_id) orelse return false;
        attachment.requestGraphicsSnapshot();
        return true;
    }

    /// Restores only graphics bytes previously consumed by one client
    /// attachment. Invalid amounts and missing panes leave all credit unchanged.
    ///
    /// ```zig
    /// const update = store.returnGraphicsCredit(credit);
    /// ```
    pub fn returnGraphicsCredit(store: *AttachmentStore, credit: schema.GraphicsCredit) GraphicsCreditUpdate {
        const attachment = store.find(credit.pane_id) orelse return .pane_not_attached;
        const bytes = std.math.cast(usize, credit.bytes) orelse return .invalid_amount;

        if (!attachment.returnGraphicsCredit(bytes)) {
            return .invalid_amount;
        }

        return .returned;
    }

    /// Accepts only the frame currently outstanding for the selected client
    /// attachment. A null result leaves every synchronization baseline intact.
    ///
    /// ```zig
    /// const elapsed = store.acknowledgeFrame(ack, received_at_ns) orelse return;
    /// ```
    pub fn acknowledgeFrame(store: *AttachmentStore, ack: schema.FrameAck, received_at_ns: u64) ?u64 {
        const attachment = store.find(ack.pane_id) orelse return null;
        return attachment.acknowledgeFrame(ack.frame_id, received_at_ns);
    }

    /// Applies a bounded viewport offset to one client attachment. Missing
    /// panes return null; allocation failure preserves the previous projection.
    ///
    /// ```zig
    /// const update = try store.setPaneViewport(viewport) orelse return;
    /// ```
    pub fn setPaneViewport(store: *AttachmentStore, viewport: schema.SetPaneViewport) !?ViewportUpdate {
        const attachment = store.find(viewport.pane_id) orelse return null;
        const changed = try attachment.setViewport(viewport.offset);
        return if (changed) .changed else .unchanged;
    }

    /// Reads one attached pane's inclusive scrollback range into caller-owned
    /// fixed storage. The returned bytes borrow `scratch`; a missing pane is
    /// distinguished from an empty or unavailable selection.
    ///
    /// ```zig
    /// const result = store.copySelection(pane_id, .{
    ///     .range = range,
    ///     .scratch = &scratch,
    /// }) orelse return;
    /// ```
    pub fn copySelection(store: *AttachmentStore, pane_id: schema.PaneId, query: SelectionQuery) ?SelectionResult {
        const attachment = store.find(pane_id) orelse return null;
        return attachment.copySelection(query.range, query.scratch);
    }

    pub fn at(store: *AttachmentStore, index: usize) ?*Attachment {
        if (index >= store.items.len) return null;
        return if (store.items[index]) |*attachment| attachment else null;
    }

    pub fn iterator(store: *const AttachmentStore) Iterator {
        return .{ .store = store };
    }

    pub fn len(store: *const AttachmentStore) usize {
        return store.count;
    }

    pub fn currentWorkspace(store: *const AttachmentStore) ?schema.WorkspaceLocation {
        return store.workspace;
    }

    /// Changes the transport policy for existing and future attachments as one
    /// aggregate update. Repeating the active policy leaves every item intact.
    ///
    /// ```zig
    /// const update = store.configureGraphics(true);
    /// ```
    pub fn configureGraphics(store: *AttachmentStore, shared: bool) GraphicsConfigurationUpdate {
        if (store.shared_graphics == shared) {
            return .unchanged;
        }

        store.shared_graphics = shared;
        for (&store.items) |*slot| {
            const attachment = if (slot.*) |*value| value else continue;
            attachment.configureGraphics(shared);
        }

        return .changed;
    }

    pub fn attach(store: *AttachmentStore, gpa: std.mem.Allocator, pane: *Pane) !*Attachment {
        std.debug.assert(pane.launch_state == .running);
        if (store.find(pane.id)) |existing| return existing;
        if (store.workspace) |workspace| {
            if (!std.meta.eql(workspace, pane.location.workspace))
                return error.WorkspaceMismatch;
        }
        if (store.count == max_panes) return error.AttachmentLimitReached;
        for (&store.items, 0..) |*slot, position| {
            if (slot.* == null) {
                slot.* = try Attachment.init(gpa, pane);
                slot.*.?.configureGraphics(store.shared_graphics);
                store.index.put(schema.id.raw(pane.id), position);
                if (store.workspace == null) store.workspace = pane.location.workspace;
                store.count += 1;
                return &slot.*.?;
            }
        }
        unreachable;
    }

    /// Removes one attachment while retaining workspace observation. The
    /// caller may need that observation to publish lifecycle events before
    /// completing departure with `leaveWorkspace`.
    ///
    /// ```zig
    /// const detached = store.detach(pane_id) orelse return;
    /// if (detached.last_attachment) {
    ///     _ = store.leaveWorkspace(detached.workspace);
    /// }
    /// ```
    pub fn detach(store: *AttachmentStore, pane_id: schema.PaneId) ?PaneDetached {
        const position = store.index.get(schema.id.raw(pane_id)) orelse return null;
        const attachment = &store.items[position].?;
        std.debug.assert(attachment.pane.id == pane_id);
        const workspace = attachment.pane.location.workspace;
        std.debug.assert(store.workspace != null and std.meta.eql(store.workspace.?, workspace));

        attachment.deinit();
        store.index.remove(schema.id.raw(pane_id));
        store.items[position] = null;
        store.count -= 1;

        return .{
            .pane_id = pane_id,
            .workspace = workspace,
            .last_attachment = store.count == 0,
        };
    }

    /// Ends observation of an empty workspace after any lifecycle event that
    /// depended on it has been published. A mismatched or non-empty store is
    /// left unchanged.
    ///
    /// ```zig
    /// if (store.leaveWorkspace(workspace)) {
    ///     release(workspace);
    /// }
    /// ```
    pub fn leaveWorkspace(store: *AttachmentStore, workspace: schema.WorkspaceLocation) bool {
        if (store.count != 0 or store.workspace == null or !std.meta.eql(store.workspace.?, workspace)) {
            return false;
        }

        store.workspace = null;
        return true;
    }

    pub fn observes(store: *const AttachmentStore, workspace: schema.WorkspaceLocation) bool {
        return store.workspace != null and std.meta.eql(store.workspace.?, workspace);
    }

    pub fn availableGraphicsCredit(store: *const AttachmentStore) usize {
        var outstanding: usize = 0;
        for (store.items) |slot| {
            const attachment = slot orelse continue;
            outstanding +|= core.graphics.max_image_bytes_per_pane -
                @min(attachment.graphicsCredit(), core.graphics.max_image_bytes_per_pane);
        }
        return core.graphics.max_image_bytes_global -|
            @min(outstanding, core.graphics.max_image_bytes_global);
    }

    /// Releases every attachment while preserving per-client configuration for
    /// the next workspace view.
    ///
    /// ```zig
    /// store.clearAttachments();
    /// ```
    pub fn clearAttachments(store: *AttachmentStore) void {
        for (&store.items) |*slot| {
            if (slot.*) |*attachment| attachment.deinit();
            slot.* = null;
        }
        store.index.reset();
        store.count = 0;
        store.workspace = null;
    }

    pub fn deinit(store: *AttachmentStore) void {
        store.clearAttachments();
        store.shared_graphics = false;
    }
};

pub fn enforceGraphicsQuotas(io: Io, pane: *Pane) void {
    // The allocator has already reserved every VT and frozen-transfer byte
    // against the pane and runtime counters. This pass only enforces count
    // limits after a complete ingest. It never touches another pane because
    // that pane may be parsing concurrently in its own actor.
    enforceGraphicsCounts(io, pane, .primary);
    enforceGraphicsCounts(io, pane, .alternate);
}

pub fn enforceGraphicsCounts(io: Io, pane: *Pane, screen_key: vt.ScreenSet.Key) void {
    const terminal = &pane.media.terminal;
    const screen = terminal.screens.get(screen_key) orelse return;
    const previous_key = terminal.screens.active_key;
    const previous = terminal.screens.active;
    terminal.screens.active_key = screen_key;
    terminal.screens.active = screen;
    defer {
        terminal.screens.active_key = previous_key;
        terminal.screens.active = previous;
    }
    const storage = &screen.kitty_images;
    const placement_limit = pane.graphics_limits.placements_per_pane / 2;
    if (storage.placements.count() > placement_limit)
        storage.delete(io, pane.media_allocator.allocator(), terminal, .{ .all = false });

    const image_limit = pane.graphics_limits.images_per_pane / 2;
    while (storage.images.count() > image_limit) {
        var oldest_id: ?u32 = null;
        var oldest_generation: u64 = std.math.maxInt(u64);
        var iterator = storage.images.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.generation >= oldest_generation) continue;
            oldest_generation = entry.value_ptr.generation;
            oldest_id = entry.key_ptr.*;
        }
        storage.delete(io, pane.media_allocator.allocator(), terminal, .{ .id = .{
            .delete = true,
            .image_id = oldest_id orelse break,
        } });
    }
}

/// Abandons the in-flight graphics batch after a media failure. The client
/// keeps whatever graphics it already holds - stale but harmless - and the
/// revision is marked observed so the send loop cannot spin on the failure.
///
/// ```zig
/// abandonGraphicsBatch(&attachment);
/// ```
pub fn abandonGraphicsBatch(attachment: *Attachment) void {
    attachment.freeTransfer();
    attachment.graphics.batch_active = false;
    attachment.graphics.snapshot = .idle;
    attachment.graphics.observed_revision = attachment.pane.graphics_revision;
}

fn encodeNextGraphics(attachment: *Attachment, preparation: Attachment.GraphicsPreparation) !?[]const u8 {
    const buffer = preparation.buffer;
    const global_credit = preparation.global_credit;
    const live_storage_available = preparation.live_storage_available;

    const pane = attachment.pane;
    const storage = &pane.media.terminal.screens.active.kitty_images;
    if (!attachment.graphics.batch_active) {
        attachment.graphics.target_revision = pane.graphics_revision;
        attachment.graphics.revision = @max(pane.graphics_revision, @as(u64, 1));
        attachment.graphics.batch_active = true;
    }
    const revision = attachment.graphics.revision;

    if (attachment.graphics.snapshot == .begin_pending) {
        attachment.graphics.known_images = [_]?graphics.Sync.KnownImage{null} ** core.graphics.max_images_per_pane;
        attachment.graphics.known_placements = [_]?graphics.Sync.KnownPlacement{null} ** core.graphics.max_placements_per_pane;
        attachment.freeTransfer();
        attachment.graphics.snapshot = .open;
        return try schema.encodeGraphicsSnapshot(buffer, .{
            .pane_id = pane.id,
            .revision = revision,
            .phase = .begin,
        });
    }

    if (attachment.graphics.transfer) |*transfer| {
        if (!transfer.metadata_sent) {
            // The flag flips only after a successful encode; on failure the
            // abandon path still owns the shared object and unlinks it.
            if (transfer.shared_name) |name| {
                const payload = try schema.encodeGraphicsSharedImage(buffer, .{
                    .pane_id = pane.id,
                    .revision = revision,
                    .image = transfer.metadata,
                    .name = name,
                });
                transfer.metadata_sent = true;
                attachment.graphics.sent_images +|= 1;
                return payload;
            }
            const payload = try schema.encodeGraphicsImage(buffer, .{
                .pane_id = pane.id,
                .revision = revision,
                .image = transfer.metadata,
            });
            transfer.metadata_sent = true;
            attachment.graphics.sent_images +|= 1;
            return payload;
        }
        if (transfer.offset < transfer.pixels.len) {
            const remaining = transfer.pixels[transfer.offset..];
            const take = @min(remaining.len, core.graphics.max_ipc_chunk_bytes);
            const offset = transfer.offset;
            transfer.offset += take;
            return try schema.encodeGraphicsImageChunk(buffer, .{
                .pane_id = pane.id,
                .revision = revision,
                .key = transfer.metadata.key,
                .offset = offset,
                .bytes = remaining[0..take],
            });
        }
        try rememberImage(attachment, transfer.metadata.key);
        if (transfer.placement_index < transfer.placement_count) {
            const placement = transfer.placements[transfer.placement_index];
            transfer.placement_index += 1;
            if (knownPlacement(attachment, placement.virtual_id)) |known|
                known.placement = placement
            else
                try rememberPlacement(attachment, placement);
            attachment.graphics.sent_placements +|= 1;
            return try schema.encodeGraphicsPlacement(buffer, .{
                .pane_id = pane.id,
                .revision = revision,
                .placement = placement,
            });
        }
        const completed_key = transfer.metadata.key;
        attachment.freeTransfer();
        forgetReplacedGenerations(attachment, completed_key);
        // The frozen copy is the only media state safe to read while the
        // pane's media actor is running. Resume the live storage walk after
        // the scheduler observes an idle media boundary.
        if (!live_storage_available) return null;
    }

    // Keep the currently displayed generation until its replacement image and
    // placements have crossed the bounded transport. Exterior IDs include the
    // generation, so both may coexist without aliasing during the handoff.
    for (&attachment.graphics.known_images) |*slot| {
        const known = slot.* orelse continue;
        const current = storage.imageById(known.key.image_id);
        if (current != null and current.?.generation == known.key.generation) continue;
        if (current) |replacement| if (!knowsImage(attachment, .{
            .image_id = replacement.id,
            .generation = replacement.generation,
        })) continue;
        slot.* = null;
        forgetPlacementsForImage(attachment, known.key);
        return try schema.encodeGraphicsDeleteImage(buffer, .{
            .pane_id = pane.id,
            .revision = revision,
            .key = known.key,
        });
    }

    switch (try stageNextTransfer(attachment, global_credit)) {
        .staged => return encodeNextGraphics(attachment, preparation),
        .blocked => return null,
        .idle => {},
    }

    for (&attachment.graphics.known_placements) |*slot| {
        const known = slot.* orelse continue;
        if (findPlacement(storage, known.placement.virtual_id) != null) continue;
        slot.* = null;
        return try schema.encodeGraphicsDeletePlacement(buffer, .{
            .pane_id = pane.id,
            .revision = revision,
            .key = known.placement.key,
            .virtual_id = known.placement.virtual_id,
            .placement_id = known.placement.placement_id,
        });
    }

    var placement_iterator = storage.placements.iterator();
    while (placement_iterator.next()) |entry| {
        const image = storage.imageById(entry.key_ptr.image_id) orelse continue;
        if (!knowsImage(attachment, .{ .image_id = image.id, .generation = image.generation }))
            continue;
        const placement = placementValue(pane, .{ .key = entry.key_ptr.*, .placement = entry.value_ptr.*, .image = image }) orelse
            continue;
        if (knownPlacement(attachment, placement.virtual_id)) |known| {
            if (std.meta.eql(known.placement, placement)) continue;
            known.placement = placement;
        } else try rememberPlacement(attachment, placement);
        attachment.graphics.sent_placements +|= 1;
        return try schema.encodeGraphicsPlacement(buffer, .{
            .pane_id = pane.id,
            .revision = revision,
            .placement = placement,
        });
    }

    attachment.graphics.observed_revision = attachment.graphics.target_revision;
    attachment.graphics.batch_active = false;
    if (attachment.graphics.snapshot == .open) {
        attachment.graphics.snapshot = .idle;
        return try schema.encodeGraphicsSnapshot(buffer, .{
            .pane_id = pane.id,
            .revision = revision,
            .phase = .end,
        });
    }
    return null;
}

pub const StageResult = enum {
    /// A transfer was frozen; the send loop can drain it without touching
    /// live storage again.
    staged,
    /// The next image exceeds the client's or the runtime's memory credit;
    /// the walk must stop until credit returns.
    blocked,
    /// Nothing left to freeze for this attachment.
    idle,
};

/// Freezes the next unknown image and its placements into the attachment.
///
/// Split out of `encodeNextGraphics` so the runtime can call it at the
/// media-idle boundary it already owns - right after `finishSealed` - rather
/// than hoping the transport happens to be ready inside that window. Live
/// storage is read here, so the caller must hold the same guarantee the send
/// loop's `live_storage_available` expresses: the pane's media actor is not
/// running. A frozen transfer then crosses the transport at any later moment,
/// which is what keeps a continuously streaming pane from ceiling out at the
/// rate of coincidences between "media idle" and "socket ready".
///
/// ```zig
/// const result = try stageNextTransfer(&attachment, global_credit);
/// ```
pub fn stageNextTransfer(attachment: *Attachment, global_credit: usize) !StageResult {
    if (attachment.graphics.transfer != null) return .staged;
    // The begin branch of the walk resets known state and frees any transfer;
    // staging before it would only create work for it to throw away.
    if (attachment.graphics.snapshot == .begin_pending) return .idle;
    const pane = attachment.pane;
    const storage = &pane.media.terminal.screens.active.kitty_images;
    var image_iterator = storage.images.iterator();
    while (image_iterator.next()) |entry| {
        const image = entry.value_ptr;
        if (image.data.bytes() == null) continue;
        const key: core.graphics.ImageKey = .{
            .image_id = image.id,
            .generation = image.generation,
        };
        if (knowsImage(attachment, key)) continue;
        const pixels = image.data.bytes() orelse continue;
        const format: core.graphics.Format = switch (image.format) {
            .rgb => .rgb,
            .rgba => .rgba,
            // Formats an internal decode path may store but the wire schema
            // does not carry. Skipping one image keeps the rest in sync and
            // the client attached; erroring here used to drop the client in
            // a reconnect loop, since the image outlives the connection.
            else => continue,
        };
        const metadata: core.graphics.Image = .{
            .key = key,
            .format = format,
            .width = image.width,
            .height = image.height,
            .byte_len = pixels.len,
        };
        _ = try metadata.validate(pane.graphics_storage_limit);
        if (pixels.len > attachment.graphics.credit or pixels.len > global_credit)
            return .blocked;
        if (!pane.media_allocator.reserveManual(pixels.len))
            return error.GraphicsQuotaExceeded;
        errdefer pane.media_allocator.releaseManual(pixels.len);
        var transfer: graphics.Sync.Transfer = .{
            .metadata = metadata,
            .pixels = &.{},
            .reserved_len = pixels.len,
        };
        if (attachment.graphics.shared_transport)
            transfer.shared_name = graphics.freezeSharedPixels(pixels);
        if (transfer.shared_name == null)
            transfer.pixels = try attachment.graphics.gpa.dupe(u8, pixels);
        attachment.graphics.credit -= pixels.len;
        attachment.graphics.transfer = transfer;
        var placement_iterator = storage.placements.iterator();
        while (placement_iterator.next()) |placement_entry| {
            if (placement_entry.key_ptr.image_id != image.id) continue;
            const placement = placementValue(pane, .{
                .key = placement_entry.key_ptr.*,
                .placement = placement_entry.value_ptr.*,
                .image = image.*,
            }) orelse continue;
            const index = attachment.graphics.transfer.?.placement_count;
            if (index == core.graphics.max_placements_per_pane) break;
            attachment.graphics.transfer.?.placements[index] = placement;
            attachment.graphics.transfer.?.placement_count += 1;
        }
        return .staged;
    }
    return .idle;
}

pub fn knowsImage(attachment: *const Attachment, key: core.graphics.ImageKey) bool {
    for (attachment.graphics.known_images) |slot| if (slot) |known| {
        if (std.meta.eql(known.key, key)) return true;
    };
    return false;
}

pub fn rememberImage(attachment: *Attachment, key: core.graphics.ImageKey) !void {
    if (knowsImage(attachment, key)) return;
    for (&attachment.graphics.known_images) |*slot| if (slot.* == null) {
        slot.* = .{ .key = key };
        return;
    };
    return error.GraphicsImageLimitReached;
}

/// Once a replacement and all of its placements have crossed the transport,
/// older generations of the same logical image no longer need attachment
/// slots. The client retires them as part of the same atomic handoff.
fn forgetReplacedGenerations(attachment: *Attachment, current: core.graphics.ImageKey) void {
    for (&attachment.graphics.known_images) |*slot| {
        const known = slot.* orelse continue;
        if (known.key.image_id == current.image_id and
            known.key.generation != current.generation)
        {
            slot.* = null;
        }
    }
}

pub fn forgetPlacementsForImage(attachment: *Attachment, key: core.graphics.ImageKey) void {
    for (&attachment.graphics.known_placements) |*slot| {
        const known = slot.* orelse continue;
        if (std.meta.eql(known.placement.key, key)) slot.* = null;
    }
}

pub fn knownPlacement(attachment: *Attachment, virtual_id: u64) ?*graphics.Sync.KnownPlacement {
    for (&attachment.graphics.known_placements) |*slot| {
        const known = if (slot.*) |*value| value else continue;
        if (known.placement.virtual_id == virtual_id) return known;
    }
    return null;
}

pub fn rememberPlacement(attachment: *Attachment, placement: core.graphics.Placement) !void {
    for (&attachment.graphics.known_placements) |*slot| if (slot.* == null) {
        slot.* = .{ .placement = placement };
        return;
    };
    return error.GraphicsPlacementLimitReached;
}

pub fn placementVirtualId(key: vt.kitty.graphics.ImageStorage.PlacementKey) u64 {
    return media_mod.placementVirtualId(key);
}

pub fn findPlacement(storage: *vt.kitty.graphics.ImageStorage, virtual_id: u64) ?vt.kitty.graphics.ImageStorage.Placement {
    var iterator = storage.placements.iterator();
    while (iterator.next()) |entry| {
        if (placementVirtualId(entry.key_ptr.*) == virtual_id) return entry.value_ptr.*;
    }
    return null;
}

fn placementValue(pane: *Pane, source: media_mod.PlacementSource) ?core.graphics.Placement {
    return media_mod.placementValue(&pane.media.terminal, source);
}

test "attachment store reports and commits workspace departure on the last pane" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var service = try history.Service.init(gpa, ":memory:");
    defer {
        service.closeQueues(io);
        service.deinit(io);
    }
    var budget = GraphicsBudget.init(core.graphics.max_image_bytes_global);
    const args = [_][*:0]const u8{ "/bin/sleep", "600" };
    const command = try pty.Command.fromArgv(&args);
    const workspace: schema.WorkspaceLocation = .{ .workspace = try schema.id.workspace(1) };
    const first = try Pane.create(.{
        .io = io,
        .gpa = gpa,
        .history_service = &service,
        .graphics_budget = &budget,
    }, .{
        .identity = .{ .id = try schema.id.pane(1), .generation = 1 },
        .location = .{ .workspace = workspace, .tab_id = try schema.id.tab(1) },
        .command = &command,
        .launch_cwd = "/",
        .workspace_path = "/",
        .size = .{ .cols = 8, .rows = 3 },
        .graphics_limits = .{},
    });
    defer {
        first.session.shutdown();
        first.destroy();
    }
    const second = try Pane.create(.{
        .io = io,
        .gpa = gpa,
        .history_service = &service,
        .graphics_budget = &budget,
    }, .{
        .identity = .{ .id = try schema.id.pane(2), .generation = 2 },
        .location = .{ .workspace = workspace, .tab_id = try schema.id.tab(1) },
        .command = &command,
        .launch_cwd = "/",
        .workspace_path = "/",
        .size = .{ .cols = 8, .rows = 3 },
        .graphics_limits = .{},
    });
    defer {
        second.session.shutdown();
        second.destroy();
    }
    first.commitLaunch("/bin/sleep");
    second.commitLaunch("/bin/sleep");
    var store: AttachmentStore = .{};
    defer store.deinit();
    _ = try store.attach(gpa, first);
    _ = try store.attach(gpa, second);

    try std.testing.expect(!store.leaveWorkspace(workspace));
    try std.testing.expect(store.detach(try schema.id.pane(99)) == null);

    const first_detached = store.detach(first.id).?;

    try std.testing.expectEqual(first.id, first_detached.pane_id);
    try std.testing.expectEqualDeep(workspace, first_detached.workspace);
    try std.testing.expect(!first_detached.last_attachment);
    try std.testing.expectEqual(@as(usize, 1), store.len());
    try std.testing.expect(store.observes(workspace));
    try std.testing.expect(store.find(first.id) == null);
    try std.testing.expect(store.find(second.id) != null);

    const second_detached = store.detach(second.id).?;

    try std.testing.expect(second_detached.last_attachment);
    try std.testing.expectEqual(@as(usize, 0), store.len());
    try std.testing.expect(store.observes(workspace));
    try std.testing.expect(!store.leaveWorkspace(.{ .workspace = try schema.id.workspace(2) }));
    try std.testing.expect(store.leaveWorkspace(workspace));
    try std.testing.expect(store.currentWorkspace() == null);
    try std.testing.expect(!store.observes(workspace));
}

test "attachments keep independent scrollback viewports" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var service = try history.Service.init(gpa, ":memory:");
    defer {
        service.closeQueues(io);
        service.deinit(io);
    }
    var budget = GraphicsBudget.init(core.graphics.max_image_bytes_global);
    const args = [_][*:0]const u8{ "/bin/sleep", "600" };
    const command = try pty.Command.fromArgv(&args);
    const pane = try Pane.create(.{
        .io = io,
        .gpa = gpa,
        .history_service = &service,
        .graphics_budget = &budget,
    }, .{
        .identity = .{ .id = try schema.id.pane(1), .generation = 1 },
        .location = .{
            .workspace = .{ .workspace = try schema.id.workspace(1) },
            .tab_id = try schema.id.tab(1),
        },
        .command = &command,
        .launch_cwd = "/",
        .workspace_path = "/",
        .size = .{ .cols = 8, .rows = 3 },
        .graphics_limits = .{},
    });
    defer {
        pane.session.shutdown();
        pane.destroy();
    }
    _ = try pane.ingest(io, "zero\r\none\r\ntwo\r\nthree\r\nfour\r\nfive\r\n");
    try pane.render(false);

    var first = try Attachment.init(gpa, pane);
    defer first.deinit();
    var second = try Attachment.init(gpa, pane);
    defer second.deinit();

    _ = try first.setViewport(0);
    const first_projection = try first.cells.project(pane, true);
    const second_projection = try second.cells.project(pane, true);
    try std.testing.expectEqual(@as(u32, 0), first_projection.scroll.offset);
    try std.testing.expect(second_projection.scroll.atBottom(pane.screen.h));
    try std.testing.expect(!std.mem.eql(
        u8,
        first_projection.buffer.cells[0].text(),
        second_projection.buffer.cells[0].text(),
    ));
    try std.testing.expect(pane.terminal.screens.active.pages.scrollbar().offset +
        pane.screen.h >= pane.terminal.screens.active.pages.scrollbar().total);
}

test "an unsupported stored image degrades graphics sync instead of killing it" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var service = try history.Service.init(gpa, ":memory:");
    defer {
        service.closeQueues(io);
        service.deinit(io);
    }
    var budget = GraphicsBudget.init(core.graphics.max_image_bytes_global);
    const args = [_][*:0]const u8{ "/bin/sleep", "600" };
    const command = try pty.Command.fromArgv(&args);
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = try schema.id.workspace(1) },
        .tab_id = try schema.id.tab(1),
    };
    const pane = try Pane.create(.{
        .io = io,
        .gpa = gpa,
        .history_service = &service,
        .graphics_budget = &budget,
    }, .{
        .identity = .{ .id = try schema.id.pane(1), .generation = 1 },
        .location = location,
        .command = &command,
        .launch_cwd = "/",
        .workspace_path = "/",
        .size = .{ .cols = 20, .rows = 5 },
        .graphics_limits = .{},
    });
    defer {
        pane.session.shutdown();
        pane.destroy();
    }

    // A gray image can only enter storage through internal decode paths, so
    // inject one directly: the sync layer must skip it, not fail the client.
    const media = pane.media_allocator.allocator();
    const pixels = try media.dupe(u8, &[_]u8{ 1, 2 });
    const screen = pane.media.terminal.screens.active;
    try screen.kitty_images.addImage(io, media, screen, .{
        .id = 42,
        .width = 2,
        .height = 1,
        .format = .gray,
        .data = .{ .complete = pixels },
    });
    pane.graphics_present = true;
    pane.graphics_revision = 1;

    var attachment = try Attachment.init(gpa, pane);
    defer attachment.deinit();
    const buffer = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(buffer);
    var messages: usize = 0;
    while (try encodeNextGraphics(&attachment, .{
        .buffer = buffer,
        .global_credit = core.graphics.max_image_bytes_global,
        .live_storage_available = true,
    })) |_| {
        messages += 1;
        try std.testing.expect(messages < 64);
    }
    try std.testing.expectEqual(graphics.SnapshotState.idle, attachment.graphics.snapshot);
    try std.testing.expectEqual(pane.graphics_revision, attachment.graphics.observed_revision);

    // Residual media errors abandon the batch and leave cells flowing.
    attachment.graphics.snapshot = .open;
    attachment.graphics.batch_active = true;
    abandonGraphicsBatch(&attachment);
    try std.testing.expectEqual(graphics.SnapshotState.idle, attachment.graphics.snapshot);
    try std.testing.expect(!attachment.graphics.batch_active);
    try std.testing.expectEqual(pane.graphics_revision, attachment.graphics.observed_revision);
}

test "graphics transfers wait for pane and client memory credit" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var service = try history.Service.init(gpa, ":memory:");
    defer {
        service.closeQueues(io);
        service.deinit(io);
    }
    var budget = GraphicsBudget.init(core.graphics.max_image_bytes_global);
    const args = [_][*:0]const u8{ "/bin/sleep", "600" };
    const command = try pty.Command.fromArgv(&args);
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = try schema.id.workspace(1) },
        .tab_id = try schema.id.tab(1),
    };
    const pane = try Pane.create(.{
        .io = io,
        .gpa = gpa,
        .history_service = &service,
        .graphics_budget = &budget,
    }, .{
        .identity = .{ .id = try schema.id.pane(1), .generation = 1 },
        .location = location,
        .command = &command,
        .launch_cwd = "/",
        .workspace_path = "/",
        .size = .{ .cols = 20, .rows = 5 },
        .graphics_limits = .{},
    });
    defer {
        pane.session.shutdown();
        pane.destroy();
    }

    const media = pane.media_allocator.allocator();
    const pixels = try media.dupe(u8, &[_]u8{ 1, 2, 3, 255 });
    const screen = pane.media.terminal.screens.active;
    try screen.kitty_images.addImage(io, media, screen, .{
        .id = 7,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = .{ .complete = pixels },
    });
    pane.graphics_present = true;
    pane.graphics_revision = 1;

    var attachment = try Attachment.init(gpa, pane);
    defer attachment.deinit();
    var buffer: [1024]u8 = undefined;

    // Snapshot framing itself consumes no image memory.
    try std.testing.expect(try encodeNextGraphics(&attachment, .{ .buffer = &buffer, .global_credit = 3, .live_storage_available = true }) != null);
    attachment.graphics.credit = 3;
    try std.testing.expect(try encodeNextGraphics(&attachment, .{ .buffer = &buffer, .global_credit = 4, .live_storage_available = true }) == null);
    try std.testing.expect(attachment.graphics.transfer == null);

    attachment.graphics.credit = 4;
    try std.testing.expect(try encodeNextGraphics(&attachment, .{ .buffer = &buffer, .global_credit = 3, .live_storage_available = true }) == null);
    try std.testing.expect(attachment.graphics.transfer == null);

    const payload = (try encodeNextGraphics(&attachment, .{ .buffer = &buffer, .global_credit = 4, .live_storage_available = true })).?;
    try std.testing.expect((try schema.decodeServer(payload)) == .graphics_image);
    try std.testing.expectEqual(@as(usize, 0), attachment.graphics.credit);
    try std.testing.expect(attachment.graphics.transfer != null);
}

test "a staged transfer drains while the media actor stays busy" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var service = try history.Service.init(gpa, ":memory:");
    defer {
        service.closeQueues(io);
        service.deinit(io);
    }
    var budget = GraphicsBudget.init(core.graphics.max_image_bytes_global);
    const args = [_][*:0]const u8{ "/bin/sleep", "600" };
    const command = try pty.Command.fromArgv(&args);
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = try schema.id.workspace(1) },
        .tab_id = try schema.id.tab(1),
    };
    const pane = try Pane.create(.{
        .io = io,
        .gpa = gpa,
        .history_service = &service,
        .graphics_budget = &budget,
    }, .{
        .identity = .{ .id = try schema.id.pane(1), .generation = 1 },
        .location = location,
        .command = &command,
        .launch_cwd = "/",
        .workspace_path = "/",
        .size = .{ .cols = 20, .rows = 5 },
        .graphics_limits = .{},
    });
    defer {
        pane.session.shutdown();
        pane.destroy();
    }

    const media = pane.media_allocator.allocator();
    const pixels = try media.dupe(u8, &[_]u8{ 1, 2, 3, 255 });
    const screen = pane.media.terminal.screens.active;
    try screen.kitty_images.addImage(io, media, screen, .{
        .id = 7,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = .{ .complete = pixels },
    });
    pane.graphics_present = true;
    pane.graphics_revision = 1;

    var attachment = try Attachment.init(gpa, pane);
    defer attachment.deinit();
    var buffer: [1024]u8 = undefined;
    const credit = core.graphics.max_image_bytes_global;

    // Staging refuses to outrun the snapshot begin, which resets the state
    // it would have written.
    try std.testing.expectEqual(StageResult.idle, try stageNextTransfer(&attachment, credit));
    try std.testing.expect((try schema.decodeServer(
        (try encodeNextGraphics(&attachment, .{ .buffer = &buffer, .global_credit = credit, .live_storage_available = true })).?,
    )) == .graphics_snapshot);

    // The runtime stages at its media-idle boundary; the send loop then
    // drains the frozen copy while the media actor is busy again.
    try std.testing.expectEqual(StageResult.staged, try stageNextTransfer(&attachment, credit));
    try std.testing.expect(attachment.graphics.transfer != null);
    try std.testing.expect((try schema.decodeServer(
        (try encodeNextGraphics(&attachment, .{ .buffer = &buffer, .global_credit = credit, .live_storage_available = false })).?,
    )) == .graphics_image);
    try std.testing.expect((try schema.decodeServer(
        (try encodeNextGraphics(&attachment, .{ .buffer = &buffer, .global_credit = credit, .live_storage_available = false })).?,
    )) == .graphics_image_chunk);
    try std.testing.expectEqual(@as(u32, 1), attachment.graphics.sent_images);

    // With the transfer drained the walk needs live storage; the batch stays
    // open instead of closing blind.
    try std.testing.expect((try encodeNextGraphics(&attachment, .{ .buffer = &buffer, .global_credit = credit, .live_storage_available = false })) == null);
    try std.testing.expect(attachment.graphics.batch_active);
    try std.testing.expect(attachment.graphics.transfer == null);

    // Once the media actor rests, the batch completes normally.
    var closed = false;
    while (try encodeNextGraphics(&attachment, .{ .buffer = &buffer, .global_credit = credit, .live_storage_available = true })) |payload| {
        const message = try schema.decodeServer(payload);
        if (message == .graphics_snapshot and message.graphics_snapshot.phase == .end)
            closed = true;
    }
    try std.testing.expect(closed);
    try std.testing.expectEqual(pane.graphics_revision, attachment.graphics.observed_revision);
}

test "completed replacements do not exhaust attachment image slots" {
    var attachment: Attachment = undefined;
    attachment.graphics.known_images =
        [_]?graphics.Sync.KnownImage{null} ** core.graphics.max_images_per_pane;

    const replacements = core.graphics.max_images_per_pane * 2;
    for (1..replacements + 1) |generation| {
        const key: core.graphics.ImageKey = .{
            .image_id = 7,
            .generation = generation,
        };
        try rememberImage(&attachment, key);
        forgetReplacedGenerations(&attachment, key);
        try std.testing.expect(knowsImage(&attachment, key));
    }

    var known_count: usize = 0;
    for (attachment.graphics.known_images) |slot| known_count += @intFromBool(slot != null);
    try std.testing.expectEqual(@as(usize, 1), known_count);
}

test "graphics quota enforcement evicts oldest images on the ingested pane" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var service = try history.Service.init(gpa, ":memory:");
    defer {
        service.closeQueues(io);
        service.deinit(io);
    }
    var budget = GraphicsBudget.init(core.graphics.max_image_bytes_global);
    const args = [_][*:0]const u8{ "/bin/sleep", "600" };
    const command = try pty.Command.fromArgv(&args);
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = try schema.id.workspace(1) },
        .tab_id = try schema.id.tab(1),
    };
    const pane = try Pane.create(.{
        .io = io,
        .gpa = gpa,
        .history_service = &service,
        .graphics_budget = &budget,
    }, .{
        .identity = .{ .id = try schema.id.pane(1), .generation = 1 },
        .location = location,
        .command = &command,
        .launch_cwd = "/",
        .workspace_path = "/",
        .size = .{ .cols = 20, .rows = 5 },
        .graphics_limits = .{ .images_per_pane = 4 },
    });
    defer {
        pane.session.shutdown();
        pane.destroy();
    }

    const media = pane.media_allocator.allocator();
    const screen = pane.media.terminal.screens.active;
    for (1..4) |image_id| {
        const pixels = try media.dupe(u8, &[_]u8{ 0, 0, 0 });
        try screen.kitty_images.addImage(io, media, screen, .{
            .id = @intCast(image_id),
            .width = 1,
            .height = 1,
            .format = .rgb,
            .data = .{ .complete = pixels },
        });
    }
    try std.testing.expectEqual(@as(usize, 3), screen.kitty_images.images.count());

    // The pass runs after this pane's own ingest completes; the limit is
    // half the configured maximum, evicting by oldest generation.
    enforceGraphicsQuotas(io, pane);
    try std.testing.expectEqual(@as(usize, 2), screen.kitty_images.images.count());
    try std.testing.expect(screen.kitty_images.imageById(1) == null);
    try std.testing.expect(screen.kitty_images.imageById(3) != null);
}

test "a shared-transport attachment ships one name instead of pixel chunks" {
    if (comptime !graphics.shared_memory_supported) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var service = try history.Service.init(gpa, ":memory:");
    defer {
        service.closeQueues(io);
        service.deinit(io);
    }
    var budget = GraphicsBudget.init(core.graphics.max_image_bytes_global);
    const args = [_][*:0]const u8{ "/bin/sleep", "600" };
    const command = try pty.Command.fromArgv(&args);
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = try schema.id.workspace(1) },
        .tab_id = try schema.id.tab(1),
    };
    const pane = try Pane.create(.{
        .io = io,
        .gpa = gpa,
        .history_service = &service,
        .graphics_budget = &budget,
    }, .{
        .identity = .{ .id = try schema.id.pane(1), .generation = 1 },
        .location = location,
        .command = &command,
        .launch_cwd = "/",
        .workspace_path = "/",
        .size = .{ .cols = 20, .rows = 5 },
        .graphics_limits = .{},
    });
    defer {
        pane.session.shutdown();
        pane.destroy();
    }

    const media = pane.media_allocator.allocator();
    const source = [_]u8{ 9, 8, 7, 255 };
    const pixels = try media.dupe(u8, &source);
    const screen = pane.media.terminal.screens.active;
    try screen.kitty_images.addImage(io, media, screen, .{
        .id = 7,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = .{ .complete = pixels },
    });
    pane.graphics_present = true;
    pane.graphics_revision = 1;

    var attachment = try Attachment.init(gpa, pane);
    defer attachment.deinit();
    attachment.graphics.shared_transport = true;
    var buffer: [1024]u8 = undefined;

    // Snapshot begin, then the complete image as one small named message.
    try std.testing.expect((try schema.decodeServer(
        (try encodeNextGraphics(&attachment, .{ .buffer = &buffer, .global_credit = core.graphics.max_image_bytes_global, .live_storage_available = true })).?,
    )) == .graphics_snapshot);
    const message = (try schema.decodeServer(
        (try encodeNextGraphics(&attachment, .{ .buffer = &buffer, .global_credit = core.graphics.max_image_bytes_global, .live_storage_available = true })).?,
    )).graphics_shared_image;
    try std.testing.expectEqual(@as(u64, 4), message.image.byte_len);

    // The named object holds exactly the frozen pixels, readable by another
    // process on this machine.
    const fd = std.c.shm_open(
        message.name.sliceZ(),
        @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })),
        @as(u16, 0),
    );
    try std.testing.expect(std.posix.errno(fd) == .SUCCESS);
    const map = try std.posix.mmap(
        null,
        source.len,
        .{ .READ = true },
        std.c.MAP{ .TYPE = .SHARED },
        fd,
        0,
    );
    _ = std.c.close(fd);
    try std.testing.expectEqualSlices(u8, &source, map[0..source.len]);
    std.posix.munmap(map);

    // Draining the batch never emits a pixel chunk; ownership of the object
    // has passed to the client, so it survives the completed transfer.
    while (try encodeNextGraphics(&attachment, .{ .buffer = &buffer, .global_credit = core.graphics.max_image_bytes_global, .live_storage_available = true })) |payload| {
        try std.testing.expect((try schema.decodeServer(payload)) != .graphics_image_chunk);
    }
    const probe = std.c.shm_open(
        message.name.sliceZ(),
        @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })),
        @as(u16, 0),
    );
    try std.testing.expect(std.posix.errno(probe) == .SUCCESS);
    _ = std.c.close(probe);
    _ = std.c.shm_unlink(message.name.sliceZ());
}

test "an abandoned unsent shared transfer unlinks its object" {
    if (comptime !graphics.shared_memory_supported) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var service = try history.Service.init(gpa, ":memory:");
    defer {
        service.closeQueues(io);
        service.deinit(io);
    }
    var budget = GraphicsBudget.init(core.graphics.max_image_bytes_global);
    const args = [_][*:0]const u8{ "/bin/sleep", "600" };
    const command = try pty.Command.fromArgv(&args);
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = try schema.id.workspace(1) },
        .tab_id = try schema.id.tab(1),
    };
    const pane = try Pane.create(.{
        .io = io,
        .gpa = gpa,
        .history_service = &service,
        .graphics_budget = &budget,
    }, .{
        .identity = .{ .id = try schema.id.pane(2), .generation = 1 },
        .location = location,
        .command = &command,
        .launch_cwd = "/",
        .workspace_path = "/",
        .size = .{ .cols = 20, .rows = 5 },
        .graphics_limits = .{},
    });
    defer {
        pane.session.shutdown();
        pane.destroy();
    }

    const name = graphics.freezeSharedPixels(&[_]u8{ 1, 2, 3, 255 }).?;
    var attachment = try Attachment.init(gpa, pane);
    defer attachment.deinit();
    attachment.graphics.transfer = .{
        .metadata = .{
            .key = .{ .image_id = 7, .generation = 1 },
            .format = .rgba,
            .width = 1,
            .height = 1,
            .byte_len = 4,
        },
        .pixels = &.{},
        .shared_name = name,
    };
    abandonGraphicsBatch(&attachment);
    const fd = std.c.shm_open(
        name.sliceZ(),
        @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })),
        @as(u16, 0),
    );
    try std.testing.expect(std.posix.errno(fd) == .NOENT);
}
