//! Per-client graphics synchronization and runtime-side KGP quotas.
//!
//! The runtime owns child image bytes and quotas; each `Attachment` tracks
//! what one client has acknowledged and streams the difference through the
//! bounded transport.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const history = @import("history/root.zig");
const media_mod = @import("media.zig");
const pane_mod = @import("pane.zig");
const pty = @import("pty.zig");

const Io = std.Io;
const schema = core.schema;
const GraphicsBudget = pane_mod.GraphicsBudget;
const Pane = pane_mod.Pane;
const SlotIndex = pane_mod.SlotIndex;
const max_panes = pane_mod.max_panes;

/// Per-client rendering state. It is disposable: reconnecting creates a fresh
/// baseline while the pane and its PTY continue to exist.
pub const Attachment = struct {
    pub const KnownImage = struct { key: core.graphics.ImageKey };
    pub const KnownPlacement = struct { placement: core.graphics.Placement };
    pub const Transfer = struct {
        metadata: core.graphics.Image,
        pixels: []u8,
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
    observed_cell_revision: u64 = 0,
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
    transfer: ?Transfer = null,
    known_images: [core.graphics.max_images_per_pane]?KnownImage =
        [_]?KnownImage{null} ** core.graphics.max_images_per_pane,
    known_placements: [core.graphics.max_placements_per_pane]?KnownPlacement =
        [_]?KnownPlacement{null} ** core.graphics.max_placements_per_pane,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, pane: *Pane) !Attachment {
        return .{
            .pane = pane,
            .acknowledged = try .init(gpa, pane.screen.w, pane.screen.h),
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
        attachment.freeTransfer();
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
        attachment.outstanding_frame_id = 0;
        attachment.snapshot_pending = true;
        return true;
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
            attachment.pane.media_allocator.releaseManual(transfer.pixels.len);
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
            transfer.metadata_sent = true;
            return try schema.encodeGraphicsImage(buffer, .{
                .pane_id = pane.id,
                .revision = revision,
                .image = transfer.metadata,
            });
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
            return try schema.encodeGraphicsPlacement(buffer, .{
                .pane_id = pane.id,
                .revision = revision,
                .placement = placement,
            });
        }
        attachment.freeTransfer();
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
        if (!pane.media_allocator.reserveManual(pixels.len))
            return error.GraphicsQuotaExceeded;
        errdefer pane.media_allocator.releaseManual(pixels.len);
        const frozen = try attachment.gpa.dupe(u8, pixels);
        attachment.transfer = .{ .metadata = metadata, .pixels = frozen };
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
        return encodeNextGraphics(buffer, attachment);
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
    while (try encodeNextGraphics(buffer, &attachment)) |_| {
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
