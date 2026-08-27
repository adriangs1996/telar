//! Per-client graphics synchronization and runtime-side KGP quotas.
//!
//! The runtime owns child image bytes and quotas; each `Attachment` tracks
//! what one client has acknowledged and streams the difference through the
//! bounded transport.

const std = @import("std");
const builtin = @import("builtin");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const history = @import("../history/root.zig");
const pane_mod = @import("../pane/root.zig");
const blit = pane_mod.blit;
const media_mod = @import("../media/root.zig");
const pty = @import("../pty/root.zig");

const Io = std.Io;
const schema = core.schema;
const diagnostics = core.diagnostics;
const GraphicsBudget = pane_mod.GraphicsBudget;
const Pane = pane_mod.Pane;
const SlotIndex = pane_mod.SlotIndex;
const max_panes = pane_mod.max_panes;

const shm_supported =
    builtin.os.tag != .windows and !builtin.abi.isAndroid() and builtin.link_libc;

/// One counter for every attachment in the process, so a name can never be
/// reused while any process might still unlink the previous owner of it.
var shared_freeze_sequence = std.atomic.Value(u64).init(0);
/// Random per-process prefix. Names stay unguessable so another local user
/// cannot squat the next one; content is protected by the 0600 mode either
/// way.
var shared_freeze_nonce = std.atomic.Value(u32).init(0);

/// Seeds the name prefix from the platform CSPRNG. Called once at server
/// startup; without it names fall back to a pid-derived prefix that is still
/// unique but guessable, which only enables the squatting nuisance above.
pub fn initSharedFreezeNonce(io: Io) void {
    var bytes: [4]u8 = undefined;
    io.random(&bytes);
    shared_freeze_nonce.store(@as(u32, @bitCast(bytes)) | 1, .monotonic);
}

/// Copies one frozen frame into a fresh runtime-owned shared memory object
/// and returns its name, or null when the platform or a race denies it and
/// the caller must fall back to the heap copy. One memcpy, no allocation.
fn freezeSharedPixels(pixels: []const u8) ?core.graphics.ShmName {
    if (comptime !shm_supported) return null;
    var nonce = shared_freeze_nonce.load(.monotonic);
    if (nonce == 0) {
        nonce = @as(u32, @bitCast(std.c.getpid())) | 1;
        shared_freeze_nonce.store(nonce, .monotonic);
    }
    const sequence = shared_freeze_sequence.fetchAdd(1, .monotonic);
    var text: [core.graphics.max_shm_name_bytes]u8 = undefined;
    const printed = std.fmt.bufPrint(&text, "/tlr{x:0>8}{x}", .{ nonce, sequence }) catch
        return null;
    const name = core.graphics.ShmName.init(printed) catch return null;
    const fd = std.c.shm_open(
        name.sliceZ(),
        @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true })),
        @as(u16, 0o600),
    );
    if (std.posix.errno(fd) != .SUCCESS) return null;
    defer _ = std.c.close(fd);
    if (std.c.ftruncate(fd, @intCast(pixels.len)) != 0) {
        _ = std.c.shm_unlink(name.sliceZ());
        return null;
    }
    const map = std.posix.mmap(
        null,
        pixels.len,
        .{ .READ = true, .WRITE = true },
        std.c.MAP{ .TYPE = .SHARED },
        fd,
        0,
    ) catch {
        _ = std.c.shm_unlink(name.sliceZ());
        return null;
    };
    defer std.posix.munmap(map);
    @memcpy(map[0..pixels.len], pixels);
    return name;
}

/// Per-client rendering state. It is disposable: reconnecting creates a fresh
/// baseline while the pane and its PTY continue to exist.
pub const Attachment = struct {
    pub const KnownImage = struct { key: core.graphics.ImageKey };
    pub const KnownPlacement = struct { placement: core.graphics.Placement };
    pub const Transfer = struct {
        metadata: core.graphics.Image,
        pixels: []u8,
        /// Set when the frozen copy lives in a runtime-owned shared memory
        /// object instead of `pixels`. The client maps it; the host terminal
        /// unlinks it after consuming, and whoever discards it first unlinks
        /// it too, which is idempotent because names are never reused.
        shared_name: ?core.graphics.ShmName = null,
        /// Bytes reserved against the media allocator for this transfer.
        /// `pixels.len` for the heap path, the image length for the shared
        /// path whose `pixels` slice stays empty.
        reserved_len: usize = 0,
        placements: [core.graphics.max_placements_per_pane]core.graphics.Placement = undefined,
        placement_count: usize = 0,
        placement_index: usize = 0,
        offset: usize = 0,
        metadata_sent: bool = false,
    };
    pub const SnapshotState = enum { begin_pending, open, idle };

    pane: *Pane,
    acknowledged: core.ui.Buffer,
    acknowledged_cursor: schema.frame.Cursor = .{},
    acknowledged_mouse: schema.frame.Mouse = .{},
    acknowledged_input_modes: schema.frame.InputModes = .{},
    acknowledged_scroll: schema.frame.Scroll = .{ .total_rows = 1, .offset = 0 },
    projected: core.ui.Buffer,
    projected_damage: []bool,
    projected_state: vt.RenderState = .empty,
    viewport_pin: ?*vt.Pin = null,
    viewport_screen: vt.ScreenSet.Key,
    observed_cell_revision: u64 = 0,
    observed_cwd_revision: u64 = 0,
    observed_foreground_revision: u64 = 0,
    next_frame_id: u64 = 1,
    acknowledged_frame_id: u64 = 0,
    outstanding_frame_id: u64 = 0,
    frame_sent_ns: u64 = 0,
    snapshot_pending: bool = true,
    exit_sent: bool = false,
    graphics_snapshot: SnapshotState = .begin_pending,
    graphics_revision: u64 = 1,
    graphics_target_revision: u64 = 0,
    graphics_batch_active: bool = false,
    observed_graphics_revision: u64 = 0,
    graphics_credit: usize = core.graphics.max_image_bytes_per_pane,
    /// The client declared it can map runtime-named shared memory. Off by
    /// default: shared transport is negotiated, never assumed, so a future
    /// remote client keeps the chunked path.
    shared_transport: bool = false,
    /// Image and placement messages encoded since the runtime last harvested
    /// them into its telemetry counters.
    sent_images: u32 = 0,
    sent_placements: u32 = 0,
    transfer: ?Transfer = null,
    known_images: [core.graphics.max_images_per_pane]?KnownImage =
        [_]?KnownImage{null} ** core.graphics.max_images_per_pane,
    known_placements: [core.graphics.max_placements_per_pane]?KnownPlacement =
        [_]?KnownPlacement{null} ** core.graphics.max_placements_per_pane,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, pane: *Pane) !Attachment {
        var acknowledged = try core.ui.Buffer.init(gpa, pane.screen.w, pane.screen.h);
        errdefer acknowledged.deinit();
        var projected = try core.ui.Buffer.init(gpa, pane.screen.w, pane.screen.h);
        errdefer projected.deinit();
        const projected_damage = try gpa.alloc(bool, pane.screen.h);
        errdefer gpa.free(projected_damage);
        @memset(projected_damage, false);
        return .{
            .pane = pane,
            .acknowledged = acknowledged,
            .projected = projected,
            .projected_damage = projected_damage,
            .viewport_screen = pane.terminal.screens.active_key,
            .gpa = gpa,
            .graphics_snapshot = if (!pane.graphics_present)
                .idle
            else
                .begin_pending,
            .observed_graphics_revision = if (!pane.graphics_present)
                pane.graphics_revision
            else
                0,
        };
    }

    pub fn deinit(attachment: *Attachment) void {
        attachment.clearViewport();
        attachment.freeTransfer();
        attachment.projected_state.deinit(attachment.gpa);
        attachment.gpa.free(attachment.projected_damage);
        attachment.projected.deinit();
        attachment.acknowledged.deinit();
    }

    pub fn resizeIfNeeded(attachment: *Attachment) !bool {
        if (attachment.acknowledged.w == attachment.pane.screen.w and
            attachment.acknowledged.h == attachment.pane.screen.h)
        {
            return false;
        }
        try attachment.acknowledged.resize(
            attachment.pane.screen.w,
            attachment.pane.screen.h,
        );
        try pane_mod.resizeScreenStorage(
            attachment.gpa,
            &attachment.projected,
            &attachment.projected_damage,
            attachment.pane.screen.w,
            attachment.pane.screen.h,
        );
        attachment.outstanding_frame_id = 0;
        attachment.snapshot_pending = true;
        return true;
    }

    fn syncViewportScreen(attachment: *Attachment) void {
        const active_key = attachment.pane.terminal.screens.active_key;
        if (attachment.viewport_screen == active_key) return;
        attachment.clearViewport();
        attachment.viewport_screen = active_key;
    }

    pub fn clearViewport(attachment: *Attachment) void {
        if (attachment.viewport_pin) |pin| {
            const screen = attachment.pane.terminal.screens.get(attachment.viewport_screen).?;
            screen.scroll(.{ .active = {} });
            screen.pages.untrackPin(pin);
        }
        attachment.viewport_pin = null;
    }

    /// Moves only this attachment. The terminal's canonical viewport is
    /// restored before returning, so another client never observes the move.
    pub fn setViewport(attachment: *Attachment, requested: u32) !void {
        const terminal_allocations = diagnostics.enterTerminalAllocations();
        defer terminal_allocations.restore();
        attachment.syncViewportScreen();
        const screen = attachment.pane.terminal.screens.active;
        if (attachment.viewport_pin) |pin| screen.scroll(.{ .pin = pin.* }) else screen.scroll(.{ .active = {} });
        screen.scroll(.{ .row = requested });
        const scrollbar = screen.pages.scrollbar();
        if (scrollbar.offset + scrollbar.len >= scrollbar.total) {
            screen.scroll(.{ .active = {} });
            attachment.clearViewport();
        } else {
            const top = screen.pages.pin(.{ .viewport = .{} }).?;
            if (attachment.viewport_pin) |pin| {
                pin.* = top;
            } else {
                attachment.viewport_pin = try screen.pages.trackPin(top);
            }
            screen.scroll(.{ .active = {} });
        }
        attachment.snapshot_pending = true;
    }

    pub const Projection = struct {
        buffer: *const core.ui.Buffer,
        damaged_rows: []const bool,
        cursor: schema.frame.Cursor,
        scroll: schema.frame.Scroll,
    };

    pub fn project(attachment: *Attachment, force: bool) !Projection {
        attachment.syncViewportScreen();
        const pane = attachment.pane;
        const screen = pane.terminal.screens.active;
        if (attachment.viewport_pin) |pin| {
            if (pin.garbage) pin.garbage = false;
            screen.scroll(.{ .pin = pin.* });
            defer screen.scroll(.{ .active = {} });
            {
                const terminal_allocations = diagnostics.enterTerminalAllocations();
                defer terminal_allocations.restore();
                try attachment.projected_state.update(attachment.gpa, &pane.terminal);
            }
            _ = blit.blit(
                &attachment.projected,
                attachment.projected.area(),
                &pane.terminal,
                &attachment.projected_state,
                .{ .force = force, .damaged_rows = attachment.projected_damage },
            );
            return .{
                .buffer = &attachment.projected,
                .damaged_rows = attachment.projected_damage,
                .cursor = .{},
                .scroll = scrollState(screen.pages.scrollbar()),
            };
        }
        return .{
            .buffer = &pane.screen,
            .damaged_rows = pane.damaged_rows,
            .cursor = pane.cursor,
            .scroll = scrollState(screen.pages.scrollbar()),
        };
    }

    fn scrollState(value: anytype) schema.frame.Scroll {
        return .{
            .total_rows = @intCast(@min(value.total, std.math.maxInt(u32))),
            .offset = @intCast(@min(value.offset, std.math.maxInt(u32))),
        };
    }

    pub fn resetGraphics(attachment: *Attachment) void {
        attachment.freeTransfer();
        attachment.graphics_snapshot = .begin_pending;
        attachment.graphics_batch_active = false;
        attachment.graphics_target_revision = 0;
        attachment.observed_graphics_revision = 0;
        attachment.transfer = null;
        attachment.known_images = [_]?KnownImage{null} ** core.graphics.max_images_per_pane;
        attachment.known_placements = [_]?KnownPlacement{null} ** core.graphics.max_placements_per_pane;
    }

    pub fn freeTransfer(attachment: *Attachment) void {
        if (attachment.transfer) |transfer| {
            attachment.gpa.free(transfer.pixels);
            attachment.pane.media_allocator.releaseManual(transfer.reserved_len);
            if (transfer.shared_name) |name| if (!transfer.metadata_sent) {
                // The client never learned this name, so nobody else can
                // reclaim the object.
                _ = std.c.shm_unlink(name.sliceZ());
            };
        }
        attachment.transfer = null;
    }
};

pub const AttachmentStore = struct {
    items: [max_panes]?Attachment = [_]?Attachment{null} ** max_panes,
    count: usize = 0,
    index: SlotIndex(2 * max_panes) = .{},
    next_send: usize = 0,
    workspace: ?schema.WorkspaceLocation = null,

    pub fn find(store: *AttachmentStore, pane_id: schema.PaneId) ?*Attachment {
        const slot = store.index.get(schema.id.raw(pane_id)) orelse return null;
        const attachment = &store.items[slot].?;
        std.debug.assert(attachment.pane.id == pane_id);
        return attachment;
    }

    pub fn attach(
        store: *AttachmentStore,
        gpa: std.mem.Allocator,
        pane: *Pane,
    ) !*Attachment {
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
                store.index.put(schema.id.raw(pane.id), position);
                if (store.workspace == null) store.workspace = pane.location.workspace;
                store.count += 1;
                return &slot.*.?;
            }
        }
        unreachable;
    }

    pub fn detach(store: *AttachmentStore, pane_id: schema.PaneId) bool {
        const position = store.index.get(schema.id.raw(pane_id)) orelse return false;
        const attachment = &store.items[position].?;
        std.debug.assert(attachment.pane.id == pane_id);
        attachment.deinit();
        store.index.remove(schema.id.raw(pane_id));
        store.items[position] = null;
        store.count -= 1;
        return true;
    }

    pub fn observes(store: *const AttachmentStore, workspace: schema.WorkspaceLocation) bool {
        return store.workspace != null and std.meta.eql(store.workspace.?, workspace);
    }

    pub fn deinit(store: *AttachmentStore) void {
        for (&store.items) |*slot| {
            if (slot.*) |*attachment| attachment.deinit();
            slot.* = null;
        }
        store.index.reset();
        store.count = 0;
        store.next_send = 0;
        store.workspace = null;
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
pub fn abandonGraphicsBatch(attachment: *Attachment) void {
    attachment.freeTransfer();
    attachment.graphics_batch_active = false;
    attachment.graphics_snapshot = .idle;
    attachment.observed_graphics_revision = attachment.pane.graphics_revision;
}

pub fn encodeNextGraphics(
    buffer: []u8,
    attachment: *Attachment,
    global_credit: usize,
    live_storage_available: bool,
) !?[]const u8 {
    const pane = attachment.pane;
    const storage = &pane.media.terminal.screens.active.kitty_images;
    if (!attachment.graphics_batch_active) {
        attachment.graphics_target_revision = pane.graphics_revision;
        attachment.graphics_revision = @max(pane.graphics_revision, @as(u64, 1));
        attachment.graphics_batch_active = true;
    }
    const revision = attachment.graphics_revision;

    if (attachment.graphics_snapshot == .begin_pending) {
        attachment.known_images = [_]?Attachment.KnownImage{null} ** core.graphics.max_images_per_pane;
        attachment.known_placements = [_]?Attachment.KnownPlacement{null} ** core.graphics.max_placements_per_pane;
        attachment.freeTransfer();
        attachment.graphics_snapshot = .open;
        return try schema.encodeGraphicsSnapshot(buffer, .{
            .pane_id = pane.id,
            .revision = revision,
            .phase = .begin,
        });
    }

    if (attachment.transfer) |*transfer| {
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
                attachment.sent_images +|= 1;
                return payload;
            }
            const payload = try schema.encodeGraphicsImage(buffer, .{
                .pane_id = pane.id,
                .revision = revision,
                .image = transfer.metadata,
            });
            transfer.metadata_sent = true;
            attachment.sent_images +|= 1;
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
            attachment.sent_placements +|= 1;
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
    for (&attachment.known_images) |*slot| {
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
        .staged => return encodeNextGraphics(
            buffer,
            attachment,
            global_credit,
            live_storage_available,
        ),
        .blocked => return null,
        .idle => {},
    }

    for (&attachment.known_placements) |*slot| {
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
        const placement = placementValue(pane, entry.key_ptr.*, entry.value_ptr.*, image) orelse
            continue;
        if (knownPlacement(attachment, placement.virtual_id)) |known| {
            if (std.meta.eql(known.placement, placement)) continue;
            known.placement = placement;
        } else try rememberPlacement(attachment, placement);
        attachment.sent_placements +|= 1;
        return try schema.encodeGraphicsPlacement(buffer, .{
            .pane_id = pane.id,
            .revision = revision,
            .placement = placement,
        });
    }

    attachment.observed_graphics_revision = attachment.graphics_target_revision;
    attachment.graphics_batch_active = false;
    if (attachment.graphics_snapshot == .open) {
        attachment.graphics_snapshot = .idle;
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
pub fn stageNextTransfer(attachment: *Attachment, global_credit: usize) !StageResult {
    if (attachment.transfer != null) return .staged;
    // The begin branch of the walk resets known state and frees any transfer;
    // staging before it would only create work for it to throw away.
    if (attachment.graphics_snapshot == .begin_pending) return .idle;
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
        if (pixels.len > attachment.graphics_credit or pixels.len > global_credit)
            return .blocked;
        if (!pane.media_allocator.reserveManual(pixels.len))
            return error.GraphicsQuotaExceeded;
        errdefer pane.media_allocator.releaseManual(pixels.len);
        var transfer: Attachment.Transfer = .{
            .metadata = metadata,
            .pixels = &.{},
            .reserved_len = pixels.len,
        };
        if (attachment.shared_transport)
            transfer.shared_name = freezeSharedPixels(pixels);
        if (transfer.shared_name == null)
            transfer.pixels = try attachment.gpa.dupe(u8, pixels);
        attachment.graphics_credit -= pixels.len;
        attachment.transfer = transfer;
        var placement_iterator = storage.placements.iterator();
        while (placement_iterator.next()) |placement_entry| {
            if (placement_entry.key_ptr.image_id != image.id) continue;
            const placement = placementValue(
                pane,
                placement_entry.key_ptr.*,
                placement_entry.value_ptr.*,
                image.*,
            ) orelse continue;
            const index = attachment.transfer.?.placement_count;
            if (index == core.graphics.max_placements_per_pane) break;
            attachment.transfer.?.placements[index] = placement;
            attachment.transfer.?.placement_count += 1;
        }
        return .staged;
    }
    return .idle;
}

pub fn knowsImage(attachment: *const Attachment, key: core.graphics.ImageKey) bool {
    for (attachment.known_images) |slot| if (slot) |known| {
        if (std.meta.eql(known.key, key)) return true;
    };
    return false;
}

pub fn rememberImage(attachment: *Attachment, key: core.graphics.ImageKey) !void {
    if (knowsImage(attachment, key)) return;
    for (&attachment.known_images) |*slot| if (slot.* == null) {
        slot.* = .{ .key = key };
        return;
    };
    return error.GraphicsImageLimitReached;
}

/// Once a replacement and all of its placements have crossed the transport,
/// older generations of the same logical image no longer need attachment
/// slots. The client retires them as part of the same atomic handoff.
fn forgetReplacedGenerations(attachment: *Attachment, current: core.graphics.ImageKey) void {
    for (&attachment.known_images) |*slot| {
        const known = slot.* orelse continue;
        if (known.key.image_id == current.image_id and
            known.key.generation != current.generation)
        {
            slot.* = null;
        }
    }
}

pub fn forgetPlacementsForImage(attachment: *Attachment, key: core.graphics.ImageKey) void {
    for (&attachment.known_placements) |*slot| {
        const known = slot.* orelse continue;
        if (std.meta.eql(known.placement.key, key)) slot.* = null;
    }
}

pub fn knownPlacement(attachment: *Attachment, virtual_id: u64) ?*Attachment.KnownPlacement {
    for (&attachment.known_placements) |*slot| {
        const known = if (slot.*) |*value| value else continue;
        if (known.placement.virtual_id == virtual_id) return known;
    }
    return null;
}

pub fn rememberPlacement(attachment: *Attachment, placement: core.graphics.Placement) !void {
    for (&attachment.known_placements) |*slot| if (slot.* == null) {
        slot.* = .{ .placement = placement };
        return;
    };
    return error.GraphicsPlacementLimitReached;
}

pub fn placementVirtualId(key: vt.kitty.graphics.ImageStorage.PlacementKey) u64 {
    return media_mod.placementVirtualId(key);
}

pub fn findPlacement(
    storage: *vt.kitty.graphics.ImageStorage,
    virtual_id: u64,
) ?vt.kitty.graphics.ImageStorage.Placement {
    var iterator = storage.placements.iterator();
    while (iterator.next()) |entry| {
        if (placementVirtualId(entry.key_ptr.*) == virtual_id) return entry.value_ptr.*;
    }
    return null;
}

pub fn placementValue(
    pane: *Pane,
    key: vt.kitty.graphics.ImageStorage.PlacementKey,
    placement: vt.kitty.graphics.ImageStorage.Placement,
    image: vt.kitty.graphics.Image,
) ?core.graphics.Placement {
    return media_mod.placementValue(&pane.media.terminal, key, placement, image);
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
    const pane = try Pane.create(
        io,
        gpa,
        .{ .id = try schema.id.pane(1), .generation = 1 },
        .{
            .workspace = .{ .workspace = try schema.id.workspace(1) },
            .tab_id = try schema.id.tab(1),
        },
        &command,
        "/",
        "/",
        &service,
        .{ .cols = 8, .rows = 3 },
        .{},
        &budget,
    );
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

    try first.setViewport(0);
    const first_projection = try first.project(true);
    const second_projection = try second.project(true);
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
    const pane = try Pane.create(
        io,
        gpa,
        .{ .id = try schema.id.pane(1), .generation = 1 },
        location,
        &command,
        "/",
        "/",
        &service,
        .{ .cols = 20, .rows = 5 },
        .{},
        &budget,
    );
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
    while (try encodeNextGraphics(
        buffer,
        &attachment,
        core.graphics.max_image_bytes_global,
        true,
    )) |_| {
        messages += 1;
        try std.testing.expect(messages < 64);
    }
    try std.testing.expectEqual(Attachment.SnapshotState.idle, attachment.graphics_snapshot);
    try std.testing.expectEqual(pane.graphics_revision, attachment.observed_graphics_revision);

    // Residual media errors abandon the batch and leave cells flowing.
    attachment.graphics_snapshot = .open;
    attachment.graphics_batch_active = true;
    abandonGraphicsBatch(&attachment);
    try std.testing.expectEqual(Attachment.SnapshotState.idle, attachment.graphics_snapshot);
    try std.testing.expect(!attachment.graphics_batch_active);
    try std.testing.expectEqual(pane.graphics_revision, attachment.observed_graphics_revision);
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
    const pane = try Pane.create(
        io,
        gpa,
        .{ .id = try schema.id.pane(1), .generation = 1 },
        location,
        &command,
        "/",
        "/",
        &service,
        .{ .cols = 20, .rows = 5 },
        .{},
        &budget,
    );
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
    try std.testing.expect(try encodeNextGraphics(&buffer, &attachment, 3, true) != null);
    attachment.graphics_credit = 3;
    try std.testing.expect(try encodeNextGraphics(&buffer, &attachment, 4, true) == null);
    try std.testing.expect(attachment.transfer == null);

    attachment.graphics_credit = 4;
    try std.testing.expect(try encodeNextGraphics(&buffer, &attachment, 3, true) == null);
    try std.testing.expect(attachment.transfer == null);

    const payload = (try encodeNextGraphics(&buffer, &attachment, 4, true)).?;
    try std.testing.expect((try schema.decodeServer(payload)) == .graphics_image);
    try std.testing.expectEqual(@as(usize, 0), attachment.graphics_credit);
    try std.testing.expect(attachment.transfer != null);
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
    const pane = try Pane.create(
        io,
        gpa,
        .{ .id = try schema.id.pane(1), .generation = 1 },
        location,
        &command,
        "/",
        "/",
        &service,
        .{ .cols = 20, .rows = 5 },
        .{},
        &budget,
    );
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
        (try encodeNextGraphics(&buffer, &attachment, credit, true)).?,
    )) == .graphics_snapshot);

    // The runtime stages at its media-idle boundary; the send loop then
    // drains the frozen copy while the media actor is busy again.
    try std.testing.expectEqual(StageResult.staged, try stageNextTransfer(&attachment, credit));
    try std.testing.expect(attachment.transfer != null);
    try std.testing.expect((try schema.decodeServer(
        (try encodeNextGraphics(&buffer, &attachment, credit, false)).?,
    )) == .graphics_image);
    try std.testing.expect((try schema.decodeServer(
        (try encodeNextGraphics(&buffer, &attachment, credit, false)).?,
    )) == .graphics_image_chunk);
    try std.testing.expectEqual(@as(u32, 1), attachment.sent_images);

    // With the transfer drained the walk needs live storage; the batch stays
    // open instead of closing blind.
    try std.testing.expect((try encodeNextGraphics(&buffer, &attachment, credit, false)) == null);
    try std.testing.expect(attachment.graphics_batch_active);
    try std.testing.expect(attachment.transfer == null);

    // Once the media actor rests, the batch completes normally.
    var closed = false;
    while (try encodeNextGraphics(&buffer, &attachment, credit, true)) |payload| {
        const message = try schema.decodeServer(payload);
        if (message == .graphics_snapshot and message.graphics_snapshot.phase == .end)
            closed = true;
    }
    try std.testing.expect(closed);
    try std.testing.expectEqual(pane.graphics_revision, attachment.observed_graphics_revision);
}

test "completed replacements do not exhaust attachment image slots" {
    var attachment: Attachment = undefined;
    attachment.known_images =
        [_]?Attachment.KnownImage{null} ** core.graphics.max_images_per_pane;

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
    for (attachment.known_images) |slot| known_count += @intFromBool(slot != null);
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
    const pane = try Pane.create(
        io,
        gpa,
        .{ .id = try schema.id.pane(1), .generation = 1 },
        location,
        &command,
        "/",
        "/",
        &service,
        .{ .cols = 20, .rows = 5 },
        .{ .images_per_pane = 4 },
        &budget,
    );
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
    if (comptime !shm_supported) return error.SkipZigTest;
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
    const pane = try Pane.create(
        io,
        gpa,
        .{ .id = try schema.id.pane(1), .generation = 1 },
        location,
        &command,
        "/",
        "/",
        &service,
        .{ .cols = 20, .rows = 5 },
        .{},
        &budget,
    );
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
    attachment.shared_transport = true;
    var buffer: [1024]u8 = undefined;

    // Snapshot begin, then the complete image as one small named message.
    try std.testing.expect((try schema.decodeServer(
        (try encodeNextGraphics(&buffer, &attachment, core.graphics.max_image_bytes_global, true)).?,
    )) == .graphics_snapshot);
    const message = (try schema.decodeServer(
        (try encodeNextGraphics(&buffer, &attachment, core.graphics.max_image_bytes_global, true)).?,
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
    while (try encodeNextGraphics(&buffer, &attachment, core.graphics.max_image_bytes_global, true)) |payload| {
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
    if (comptime !shm_supported) return error.SkipZigTest;
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
    const pane = try Pane.create(
        io,
        gpa,
        .{ .id = try schema.id.pane(2), .generation = 1 },
        location,
        &command,
        "/",
        "/",
        &service,
        .{ .cols = 20, .rows = 5 },
        .{},
        &budget,
    );
    defer {
        pane.session.shutdown();
        pane.destroy();
    }

    const name = freezeSharedPixels(&[_]u8{ 1, 2, 3, 255 }).?;
    var attachment = try Attachment.init(gpa, pane);
    defer attachment.deinit();
    attachment.transfer = .{
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
