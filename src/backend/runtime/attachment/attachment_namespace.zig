//! Per-client synchronization of one runtime-owned pane.
//!
//! `Attachment` is the supported seam. Cell projection and graphics transfer
//! remain private synchronization modules with independent state and budgets.
const kitty_protocol = @import("kitty_protocol");

const core = @import("telar-core");
const std = @import("std");
const shared_transfer = @import("../../media/shared_transfer.zig");
const Pane = @import("../../pane/Pane.zig");
const vt = @import("ghostty-vt");
const Attachment = @import("Attachment.zig");
const GraphicsPreparation = @import("GraphicsPreparation.zig");
const KnownImage = @import("KnownImage.zig");
const KnownPlacement = @import("KnownPlacement.zig");
const Transfer = @import("Transfer.zig");
const media_mod = @import("../../media/media.zig");
const PlacementSource = @import("../../media/PlacementSource.zig");
const graphics = @import("graphics.zig");
const GraphicsTrim = @import("GraphicsTrim.zig");

pub fn initSharedFreezeNonce(io: std.Io) void {
    shared_transfer.initSharedFreezeNonce(io);
}

/// Keeps each screen of `pane` within its image and placement counts after
/// a complete ingest and returns what it dropped, for the caller to report.
///
/// ```zig
/// const trim = attachment_namespace.enforceGraphicsQuotas(io, pane);
/// ```
pub fn enforceGraphicsQuotas(io: std.Io, pane: *Pane) GraphicsTrim {
    // The allocator has already reserved every VT and frozen-transfer byte
    // against the pane and runtime counters. This pass only enforces count
    // limits after a complete ingest. It never touches another pane because
    // that pane may be parsing concurrently in its own actor.
    var trim = enforceGraphicsCounts(io, pane, .primary);
    trim.add(enforceGraphicsCounts(io, pane, .alternate));
    return trim;
}

/// Drops the oldest images of one screen past its image count, then only
/// the placements past its placement count: first those scrolled out of the
/// screen, then those of the oldest images, so what the child drew last
/// stays.
///
/// ```zig
/// const trim = attachment_namespace.enforceGraphicsCounts(io, pane, .primary);
/// ```
pub fn enforceGraphicsCounts(io: std.Io, pane: *Pane, screen_key: vt.ScreenSet.Key) GraphicsTrim {
    const terminal = &pane.media.terminal;
    const screen = terminal.screens.get(screen_key) orelse return .{};
    const previous_key = terminal.screens.active_key;
    const previous = terminal.screens.active;
    terminal.screens.active_key = screen_key;
    terminal.screens.active = screen;
    defer {
        terminal.screens.active_key = previous_key;
        terminal.screens.active = previous;
    }

    var trim: GraphicsTrim = .{};
    const storage = &screen.kitty_images;
    const image_limit = pane.graphics_limits.images_per_pane / 2;
    trim.images_found = storage.images.count();
    while (storage.images.count() > image_limit) {
        const oldest_id = oldestImage(storage, false) orelse break;
        storage.delete(io, pane.media_allocator.allocator(), terminal, .{ .id = .{
            .delete = true,
            .image_id = oldest_id,
        } });
        trim.images_dropped += 1;
    }

    const placement_limit = pane.graphics_limits.placements_per_pane / 2;
    trim.placements_found = storage.placements.count();
    if (trim.placements_found > placement_limit) {
        trim.placements_dropped = trimPlacements(terminal, storage, placement_limit);
        storage.dirty = true;
        storage.generation = vt.kitty.graphics.nextGeneration(io);
    }

    return trim;
}

const PlacementEntry = @FieldType(vt.kitty.graphics.ImageStorage, "placements").Entry;

fn oldestImage(storage: *const vt.kitty.graphics.ImageStorage, placed: bool) ?u32 {
    var oldest_id: ?u32 = null;
    var oldest_generation: u64 = std.math.maxInt(u64);
    var iterator = storage.images.iterator();
    while (iterator.next()) |entry| {
        if (placed and entry.value_ptr.metadata.placement_count == 0) {
            continue;
        }

        if (entry.value_ptr.generation >= oldest_generation) {
            continue;
        }

        oldest_generation = entry.value_ptr.generation;
        oldest_id = entry.key_ptr.*;
    }

    return oldest_id;
}

/// Drops placements until `limit` remain, in passes over the placement
/// map: one for the placements wholly outside the screen, then one per
/// image from the oldest. The images stay, within their own count.
fn trimPlacements(terminal: *vt.Terminal, storage: *vt.kitty.graphics.ImageStorage, limit: usize) usize {
    const found = storage.placements.count();
    var offscreen = storage.placements.iterator();
    while (storage.placements.count() > limit) {
        const entry = offscreen.next() orelse break;
        if (placementVisible(terminal, storage, entry.key_ptr.*, entry.value_ptr)) {
            continue;
        }

        removePlacement(terminal, storage, entry);
    }

    while (storage.placements.count() > limit) {
        const image_id = oldestImage(storage, true) orelse break;
        var placements = storage.placements.iterator();
        while (storage.placements.count() > limit) {
            const entry = placements.next() orelse break;
            if (entry.key_ptr.image_id == image_id) {
                removePlacement(terminal, storage, entry);
            }
        }
    }

    return found - storage.placements.count();
}

fn placementVisible(terminal: *vt.Terminal, storage: *const vt.kitty.graphics.ImageStorage, key: vt.kitty.graphics.ImageStorage.PlacementKey, placement: *const vt.kitty.graphics.ImageStorage.Placement) bool {
    const pin = switch (placement.location) {
        .pin => |pin| pin,
        .virtual => return true,
    };
    if (pin.garbage) {
        return false;
    }

    const pages = &terminal.screens.active.pages;
    if (pages.pointFromPin(.active, pin.*) != null) {
        return true;
    }

    const image = storage.imageById(key.image_id) orelse return false;
    const rect = placement.rect(image, terminal) orelse return false;
    return pages.pointFromPin(.active, rect.bottom_right) != null;
}

fn removePlacement(terminal: *vt.Terminal, storage: *vt.kitty.graphics.ImageStorage, entry: PlacementEntry) void {
    entry.value_ptr.deinit(terminal.screens.active);
    const image = storage.images.getPtr(entry.key_ptr.image_id).?;
    image.metadata.placement_count -= 1;
    storage.placements.removeByPtr(entry.key_ptr);
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

pub fn encodeNextGraphics(attachment: *Attachment, preparation: GraphicsPreparation) !?[]const u8 {
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
        attachment.graphics.known_images = [_]?KnownImage{null} ** core.max_images_per_pane;
        attachment.graphics.known_placements = [_]?KnownPlacement{null} ** core.max_placements_per_pane;
        attachment.freeTransfer();
        attachment.graphics.snapshot = .open;
        return try core.encodeGraphicsSnapshot(buffer, .{
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
                const payload = try core.encodeGraphicsSharedImage(buffer, .{
                    .pane_id = pane.id,
                    .revision = revision,
                    .image = transfer.metadata,
                    .name = name,
                });
                transfer.metadata_sent = true;
                attachment.graphics.sent_images +|= 1;
                return payload;
            }
            const payload = try core.encodeGraphicsImage(buffer, .{
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
            const take = @min(remaining.len, core.max_ipc_chunk_bytes);
            const offset = transfer.offset;
            transfer.offset += take;
            return try core.encodeGraphicsImageChunk(buffer, .{
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
            if (knownPlacement(attachment, placement.virtual_id)) |known| {
                known.placement = placement;
            } else {
                try rememberPlacement(attachment, placement);
            }
            attachment.graphics.sent_placements +|= 1;
            return try core.encodeGraphicsPlacement(buffer, .{
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
        if (!live_storage_available) {
            return null;
        }
    }

    // Keep the currently displayed generation until its replacement image and
    // placements have crossed the bounded transport. Exterior IDs include the
    // generation, so both may coexist without aliasing during the handoff.
    for (&attachment.graphics.known_images) |*slot| {
        const known = slot.* orelse continue;
        const current = storage.imageById(known.key.image_id);
        if (current != null and current.?.generation == known.key.generation) {
            continue;
        }
        if (current) |replacement| {
            if (!knowsImage(attachment, .{
                .image_id = replacement.id,
                .generation = replacement.generation,
            })) {
                continue;
            }
        }
        slot.* = null;
        forgetPlacementsForImage(attachment, known.key);
        return try core.encodeGraphicsDeleteImage(buffer, .{
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
        if (placementProjects(pane, storage, known.placement.virtual_id)) {
            continue;
        }
        slot.* = null;
        return try core.encodeGraphicsDeletePlacement(buffer, .{
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
        if (!knowsImage(attachment, .{ .image_id = image.id, .generation = image.generation })) {
            continue;
        }
        const placement = placementValue(pane, .{ .key = entry.key_ptr.*, .placement = entry.value_ptr.*, .image = image }) orelse
            continue;
        if (knownPlacement(attachment, placement.virtual_id)) |known| {
            if (std.meta.eql(known.placement, placement)) {
                continue;
            }
            known.placement = placement;
        } else {
            try rememberPlacement(attachment, placement);
        }
        attachment.graphics.sent_placements +|= 1;
        return try core.encodeGraphicsPlacement(buffer, .{
            .pane_id = pane.id,
            .revision = revision,
            .placement = placement,
        });
    }

    attachment.graphics.observed_revision = attachment.graphics.target_revision;
    attachment.graphics.batch_active = false;
    if (attachment.graphics.snapshot == .open) {
        attachment.graphics.snapshot = .idle;
        return try core.encodeGraphicsSnapshot(buffer, .{
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
    if (attachment.graphics.transfer != null) {
        return .staged;
    }
    // The begin branch of the walk resets known state and frees any transfer;
    // staging before it would only create work for it to throw away.
    if (attachment.graphics.snapshot == .begin_pending) {
        return .idle;
    }
    const pane = attachment.pane;
    const storage = &pane.media.terminal.screens.active.kitty_images;
    var image_iterator = storage.images.iterator();
    while (image_iterator.next()) |entry| {
        const image = entry.value_ptr;
        const pixels = pane.media_allocator.imagePixels(image.data.bytes()) orelse continue;
        const key: core.ImageKey = .{
            .image_id = image.id,
            .generation = image.generation,
        };
        if (knowsImage(attachment, key)) {
            continue;
        }
        const format: kitty_protocol.Format = switch (image.format) {
            .rgb => .rgb,
            .rgba => .rgba,
            // Formats an internal decode path may store but the wire schema
            // does not carry. Skipping one image keeps the rest in sync and
            // the client attached; erroring here used to drop the client in
            // a reconnect loop, since the image outlives the connection.
            else => continue,
        };
        const metadata: core.Image = .{
            .key = key,
            .format = format,
            .width = image.width,
            .height = image.height,
            .byte_len = pixels.len,
        };
        _ = try metadata.validate(pane.graphics_storage_limit);
        if (pixels.len > attachment.graphics.credit or pixels.len > global_credit) {
            attachment.graphics.stage_blocked +|= 1;
            return .blocked;
        }
        var transfer: Transfer = .{
            .metadata = metadata,
            .pixels = &.{},
            .reserved_len = pixels.len,
        };
        // The media actor may already have frozen this generation with the
        // pixels hot; adopting it costs the runtime thread nothing.
        if (attachment.graphics.shared_transport) {
            if (pane.media_ingestion.prepared_transfers.take(key)) |prepared| {
                transfer.shared_name = prepared.name;
                transfer.reserved_len = prepared.reserved_len;
                attachment.graphics.adopted +|= 1;
            }
        }
        if (transfer.shared_name == null) {
            const request: @TypeOf(pane.media_ingestion.transfer_preparation).Input = .{ .key = key, .shared_transport = attachment.graphics.shared_transport, .allocator = attachment.graphics.gpa };
            if (try pane.media_ingestion.transfer_preparation.take(request)) |frozen| {
                transfer.shared_name = frozen.name;
                transfer.pixels = frozen.pixels;
                transfer.reserved_len = frozen.reserved_len;
                attachment.graphics.adopted +|= 1;
            } else {
                if (pane.media_ingestion.transfer_preparation.request(request)) {
                    // An empty output event wakes the existing single-flight
                    // media actor without parsing or copying image bytes here.
                    pane.queueMediaOutput(&.{});
                }

                return .blocked;
            }
        }
        attachment.graphics.credit -= pixels.len;
        attachment.graphics.transfer = transfer;
        var placement_iterator = storage.placements.iterator();
        while (placement_iterator.next()) |placement_entry| {
            if (placement_entry.key_ptr.image_id != image.id) {
                continue;
            }
            const placement = placementValue(pane, .{
                .key = placement_entry.key_ptr.*,
                .placement = placement_entry.value_ptr.*,
                .image = image.*,
            }) orelse continue;
            const index = attachment.graphics.transfer.?.placement_count;
            if (index == core.max_placements_per_pane) {
                break;
            }
            attachment.graphics.transfer.?.placements[index] = placement;
            attachment.graphics.transfer.?.placement_count += 1;
        }
        return .staged;
    }
    return .idle;
}

pub fn knowsImage(attachment: *const Attachment, key: core.ImageKey) bool {
    for (attachment.graphics.known_images) |slot| if (slot) |known| {
        if (std.meta.eql(known.key, key)) {
            return true;
        }
    };
    return false;
}

pub fn rememberImage(attachment: *Attachment, key: core.ImageKey) !void {
    if (knowsImage(attachment, key)) {
        return;
    }
    for (&attachment.graphics.known_images) |*slot| if (slot.* == null) {
        slot.* = .{ .key = key };
        return;
    };
    return error.GraphicsImageLimitReached;
}

/// Once a replacement and all of its placements have crossed the transport,
/// older generations of the same logical image no longer need attachment
/// slots. The client retires them as part of the same atomic handoff.
fn forgetReplacedGenerations(attachment: *Attachment, current: core.ImageKey) void {
    for (&attachment.graphics.known_images) |*slot| {
        const known = slot.* orelse continue;
        if (known.key.image_id == current.image_id and
            known.key.generation != current.generation)
        {
            slot.* = null;
        }
    }
}

pub fn forgetPlacementsForImage(attachment: *Attachment, key: core.ImageKey) void {
    for (&attachment.graphics.known_placements) |*slot| {
        const known = slot.* orelse continue;
        if (std.meta.eql(known.placement.key, key)) {
            slot.* = null;
        }
    }
}

pub fn knownPlacement(attachment: *Attachment, virtual_id: u64) ?*KnownPlacement {
    for (&attachment.graphics.known_placements) |*slot| {
        const known = if (slot.*) |*value| value else continue;
        if (known.placement.virtual_id == virtual_id) {
            return known;
        }
    }
    return null;
}

pub fn rememberPlacement(attachment: *Attachment, placement: core.Placement) !void {
    for (&attachment.graphics.known_placements) |*slot| if (slot.* == null) {
        slot.* = .{ .placement = placement };
        return;
    };
    return error.GraphicsPlacementLimitReached;
}

pub fn placementVirtualId(key: vt.kitty.graphics.ImageStorage.PlacementKey) u64 {
    return media_mod.placementVirtualId(key);
}

// Whether a placement the client knows still has a position to send: a pin
// whose history the media terminal pruned no longer does, and the client
// must drop it rather than keep drawing it where it last was.
fn placementProjects(pane: *Pane, storage: *vt.kitty.graphics.ImageStorage, virtual_id: u64) bool {
    var iterator = storage.placements.iterator();
    while (iterator.next()) |entry| {
        if (placementVirtualId(entry.key_ptr.*) != virtual_id) {
            continue;
        }

        const image = storage.imageById(entry.key_ptr.image_id) orelse return false;
        return placementValue(pane, .{
            .key = entry.key_ptr.*,
            .placement = entry.value_ptr.*,
            .image = image,
        }) != null;
    }

    return false;
}

fn placementValue(pane: *Pane, source: PlacementSource) ?core.Placement {
    return media_mod.placementValue(&pane.media.terminal, source);
}
