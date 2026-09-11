//! Per-client synchronization of one runtime-owned pane.
//!
//! `Attachment` is the supported seam. Cell projection and graphics transfer
//! remain private synchronization modules with independent state and budgets.

const std = @import("std");
const shared_transfer = @import("../../media/shared_transfer.zig");
const Pane = @import("../../pane/Pane.zig");
const vt = @import("ghostty-vt");
const Attachment = @import("Attachment.zig");
const GraphicsPreparationType = @import("GraphicsPreparation.zig");
const KnownImageType = @import("KnownImage.zig");
const max_images_per_pane_module = @import("telar-core").max_images_per_pane;
const KnownPlacementType = @import("KnownPlacement.zig");
const max_placements_per_pane_module = @import("telar-core").max_placements_per_pane;
const encodeGraphicsSnapshot_module = @import("telar-core").encodeGraphicsSnapshot;
const encodeGraphicsSharedImage_module = @import("telar-core").encodeGraphicsSharedImage;
const encodeGraphicsImage_module = @import("telar-core").encodeGraphicsImage;
const max_ipc_chunk_bytes_module = @import("telar-core").max_ipc_chunk_bytes;
const encodeGraphicsImageChunk_module = @import("telar-core").encodeGraphicsImageChunk;
const encodeGraphicsPlacement_module = @import("telar-core").encodeGraphicsPlacement;
const encodeGraphicsDeleteImage_module = @import("telar-core").encodeGraphicsDeleteImage;
const encodeGraphicsDeletePlacement_module = @import("telar-core").encodeGraphicsDeletePlacement;
const ImageKeyType = @import("telar-core").ImageKey;
const FormatType = @import("telar-core").Format;
const ImageType = @import("telar-core").Image;
const TransferType = @import("Transfer.zig");
const PlacementType = @import("telar-core").Placement;
const media_mod = @import("../../media/media.zig");
const PlacementSourceType = @import("../../media/PlacementSource.zig");
const ServiceType = @import("../../history/Service.zig");
const GraphicsBudget = @import("../../media/GraphicsBudget.zig");
const max_image_bytes_global_module = @import("telar-core").max_image_bytes_global;
const CommandType = @import("../../pty/Command.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const workspace_module = @import("telar-core").workspace;
const pane_module = @import("telar-core").pane;
const tab_module = @import("telar-core").tab;
const AttachmentStore = @import("AttachmentStore.zig");
const support_module = @import("../tests/support.zig");
const CellPreparationType = @import("CellPreparation.zig");
const decodeServer_module = @import("telar-core").decodeServer;
const PointerShapeType = @import("telar-core").PointerShape;
const TabLocationType = @import("telar-core").TabLocation;
const graphics = @import("graphics.zig");

pub fn initSharedFreezeNonce(io: std.Io) void {
    shared_transfer.initSharedFreezeNonce(io);
}

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

pub fn enforceGraphicsQuotas(io: std.Io, pane: *Pane) void {
    // The allocator has already reserved every VT and frozen-transfer byte
    // against the pane and runtime counters. This pass only enforces count
    // limits after a complete ingest. It never touches another pane because
    // that pane may be parsing concurrently in its own actor.
    enforceGraphicsCounts(io, pane, .primary);
    enforceGraphicsCounts(io, pane, .alternate);
}

pub fn enforceGraphicsCounts(io: std.Io, pane: *Pane, screen_key: vt.ScreenSet.Key) void {
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
    if (storage.placements.count() > placement_limit) {
        storage.delete(io, pane.media_allocator.allocator(), terminal, .{ .all = false });
    }

    const image_limit = pane.graphics_limits.images_per_pane / 2;
    while (storage.images.count() > image_limit) {
        var oldest_id: ?u32 = null;
        var oldest_generation: u64 = std.math.maxInt(u64);
        var iterator = storage.images.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.generation >= oldest_generation) {
                continue;
            }
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

pub fn encodeNextGraphics(attachment: *Attachment, preparation: GraphicsPreparationType) !?[]const u8 {
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
        attachment.graphics.known_images = [_]?KnownImageType{null} ** max_images_per_pane_module;
        attachment.graphics.known_placements = [_]?KnownPlacementType{null} ** max_placements_per_pane_module;
        attachment.freeTransfer();
        attachment.graphics.snapshot = .open;
        return try encodeGraphicsSnapshot_module(buffer, .{
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
                const payload = try encodeGraphicsSharedImage_module(buffer, .{
                    .pane_id = pane.id,
                    .revision = revision,
                    .image = transfer.metadata,
                    .name = name,
                });
                transfer.metadata_sent = true;
                attachment.graphics.sent_images +|= 1;
                return payload;
            }
            const payload = try encodeGraphicsImage_module(buffer, .{
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
            const take = @min(remaining.len, max_ipc_chunk_bytes_module);
            const offset = transfer.offset;
            transfer.offset += take;
            return try encodeGraphicsImageChunk_module(buffer, .{
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
            return try encodeGraphicsPlacement_module(buffer, .{
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
        return try encodeGraphicsDeleteImage_module(buffer, .{
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
        if (findPlacement(storage, known.placement.virtual_id) != null) {
            continue;
        }
        slot.* = null;
        return try encodeGraphicsDeletePlacement_module(buffer, .{
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
        return try encodeGraphicsPlacement_module(buffer, .{
            .pane_id = pane.id,
            .revision = revision,
            .placement = placement,
        });
    }

    attachment.graphics.observed_revision = attachment.graphics.target_revision;
    attachment.graphics.batch_active = false;
    if (attachment.graphics.snapshot == .open) {
        attachment.graphics.snapshot = .idle;
        return try encodeGraphicsSnapshot_module(buffer, .{
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
        const key: ImageKeyType = .{
            .image_id = image.id,
            .generation = image.generation,
        };
        if (knowsImage(attachment, key)) {
            continue;
        }
        const format: FormatType = switch (image.format) {
            .rgb => .rgb,
            .rgba => .rgba,
            // Formats an internal decode path may store but the wire schema
            // does not carry. Skipping one image keeps the rest in sync and
            // the client attached; erroring here used to drop the client in
            // a reconnect loop, since the image outlives the connection.
            else => continue,
        };
        const metadata: ImageType = .{
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
        var transfer: TransferType = .{
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
            if (index == max_placements_per_pane_module) {
                break;
            }
            attachment.graphics.transfer.?.placements[index] = placement;
            attachment.graphics.transfer.?.placement_count += 1;
        }
        return .staged;
    }
    return .idle;
}

pub fn knowsImage(attachment: *const Attachment, key: ImageKeyType) bool {
    for (attachment.graphics.known_images) |slot| if (slot) |known| {
        if (std.meta.eql(known.key, key)) {
            return true;
        }
    };
    return false;
}

pub fn rememberImage(attachment: *Attachment, key: ImageKeyType) !void {
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
fn forgetReplacedGenerations(attachment: *Attachment, current: ImageKeyType) void {
    for (&attachment.graphics.known_images) |*slot| {
        const known = slot.* orelse continue;
        if (known.key.image_id == current.image_id and
            known.key.generation != current.generation)
        {
            slot.* = null;
        }
    }
}

pub fn forgetPlacementsForImage(attachment: *Attachment, key: ImageKeyType) void {
    for (&attachment.graphics.known_placements) |*slot| {
        const known = slot.* orelse continue;
        if (std.meta.eql(known.placement.key, key)) {
            slot.* = null;
        }
    }
}

pub fn knownPlacement(attachment: *Attachment, virtual_id: u64) ?*KnownPlacementType {
    for (&attachment.graphics.known_placements) |*slot| {
        const known = if (slot.*) |*value| value else continue;
        if (known.placement.virtual_id == virtual_id) {
            return known;
        }
    }
    return null;
}

pub fn rememberPlacement(attachment: *Attachment, placement: PlacementType) !void {
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
        if (placementVirtualId(entry.key_ptr.*) == virtual_id) {
            return entry.value_ptr.*;
        }
    }
    return null;
}

fn placementValue(pane: *Pane, source: PlacementSourceType) ?PlacementType {
    return media_mod.placementValue(&pane.media.terminal, source);
}

test "attachment store reports and commits workspace departure on the last pane" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var service = try ServiceType.init(gpa, .{ .database_path = ":memory:" });
    defer {
        service.stop(io);
        service.deinit(io);
    }
    var budget = GraphicsBudget.init(max_image_bytes_global_module);
    const args = [_][*:0]const u8{ "/bin/sleep", "600" };
    const command = try CommandType.fromArgv(&args);
    const workspace: WorkspaceLocationType = .{ .workspace = try workspace_module(1) };
    const first = try Pane.create(.{
        .io = io,
        .gpa = gpa,
        .history_service = &service,
        .graphics_budget = &budget,
    }, .{
        .identity = .{ .id = try pane_module(1), .generation = 1 },
        .location = .{ .workspace = workspace, .tab_id = try tab_module(1) },
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
        .identity = .{ .id = try pane_module(2), .generation = 2 },
        .location = .{ .workspace = workspace, .tab_id = try tab_module(1) },
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
    try std.testing.expect(store.detach(try pane_module(99)) == null);

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
    try std.testing.expect(!store.leaveWorkspace(.{ .workspace = try workspace_module(2) }));
    try std.testing.expect(store.leaveWorkspace(workspace));
    try std.testing.expect(store.currentWorkspace() == null);
    try std.testing.expect(!store.observes(workspace));
}

test "pointer-only frames coalesce independently and survive snapshot recovery" {
    const support = support_module;
    var fixture: support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var first = try Attachment.init(std.testing.allocator, fixture.pane);
    defer first.deinit();
    var second = try Attachment.init(std.testing.allocator, fixture.pane);
    defer second.deinit();
    var buffer: [4096]u8 = undefined;
    const preparation: CellPreparationType = .{ .io = std.testing.io, .buffer = &buffer, .metrics = &fixture.metrics };

    const initial = (try decodeServer_module((try first.prepareNextCells(preparation)).?.bytes)).pane_frame;
    try std.testing.expectEqual(PointerShapeType.text, initial.pointer_shape);
    _ = first.acknowledgeFrame(initial.frame_id, 0);
    const slow = (try decodeServer_module((try second.prepareNextCells(preparation)).?.bytes)).pane_frame;
    const slow_id = slow.frame_id;
    _ = try fixture.pane.ingest(std.testing.io, "\x1b]22;pointer\x1b\\");
    const changed = (try decodeServer_module((try first.prepareNextCells(preparation)).?.bytes)).pane_frame;
    try std.testing.expectEqual(PointerShapeType.pointer, changed.pointer_shape);
    try std.testing.expectEqual(@as(u16, 0), changed.span_count);
    try std.testing.expectEqual(initial.frame_id, changed.base_frame_id);
    _ = first.acknowledgeFrame(changed.frame_id, 0);
    try std.testing.expect((try first.prepareNextCells(preparation)) == null);
    try std.testing.expect((try second.prepareNextCells(preparation)) == null);

    _ = try fixture.pane.ingest(std.testing.io, "\x1b]22;wait\x1b\\\x1b]22;zoom-in\x1b\\");
    const latest = (try decodeServer_module((try first.prepareNextCells(preparation)).?.bytes)).pane_frame;
    try std.testing.expectEqual(PointerShapeType.zoom_in, latest.pointer_shape);
    try std.testing.expectEqual(@as(u16, 0), latest.span_count);
    _ = first.acknowledgeFrame(latest.frame_id, 0);
    try std.testing.expect((try second.prepareNextCells(preparation)) == null);
    _ = second.acknowledgeFrame(slow_id, 0);
    const caught_up = (try decodeServer_module((try second.prepareNextCells(preparation)).?.bytes)).pane_frame;
    try std.testing.expectEqual(PointerShapeType.zoom_in, caught_up.pointer_shape);
    try std.testing.expectEqual(@as(u16, 0), caught_up.span_count);
    try std.testing.expectEqual(slow_id, caught_up.base_frame_id);

    first.requestCellSnapshot();
    const recovered = (try decodeServer_module((try first.prepareNextCells(preparation)).?.bytes)).pane_frame;
    try std.testing.expectEqual(PointerShapeType.zoom_in, recovered.pointer_shape);
    try std.testing.expect(recovered.isSnapshot());
    var reconnected = try Attachment.init(std.testing.allocator, fixture.pane);
    defer reconnected.deinit();
    const restored = (try decodeServer_module((try reconnected.prepareNextCells(preparation)).?.bytes)).pane_frame;
    try std.testing.expectEqual(PointerShapeType.zoom_in, restored.pointer_shape);
    try std.testing.expect(restored.isSnapshot());
}

test "attachments keep independent scrollback viewports" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var service = try ServiceType.init(gpa, .{ .database_path = ":memory:" });
    defer {
        service.stop(io);
        service.deinit(io);
    }
    var budget = GraphicsBudget.init(max_image_bytes_global_module);
    const args = [_][*:0]const u8{ "/bin/sleep", "600" };
    const command = try CommandType.fromArgv(&args);
    const pane = try Pane.create(.{
        .io = io,
        .gpa = gpa,
        .history_service = &service,
        .graphics_budget = &budget,
    }, .{
        .identity = .{ .id = try pane_module(1), .generation = 1 },
        .location = .{
            .workspace = .{ .workspace = try workspace_module(1) },
            .tab_id = try tab_module(1),
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
    var service = try ServiceType.init(gpa, .{ .database_path = ":memory:" });
    defer {
        service.stop(io);
        service.deinit(io);
    }
    var budget = GraphicsBudget.init(max_image_bytes_global_module);
    const args = [_][*:0]const u8{ "/bin/sleep", "600" };
    const command = try CommandType.fromArgv(&args);
    const location: TabLocationType = .{
        .workspace = .{ .workspace = try workspace_module(1) },
        .tab_id = try tab_module(1),
    };
    const pane = try Pane.create(.{
        .io = io,
        .gpa = gpa,
        .history_service = &service,
        .graphics_budget = &budget,
    }, .{
        .identity = .{ .id = try pane_module(1), .generation = 1 },
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
        .global_credit = max_image_bytes_global_module,
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
    var service = try ServiceType.init(gpa, .{ .database_path = ":memory:" });
    defer {
        service.stop(io);
        service.deinit(io);
    }
    var budget = GraphicsBudget.init(max_image_bytes_global_module);
    const args = [_][*:0]const u8{ "/bin/sleep", "600" };
    const command = try CommandType.fromArgv(&args);
    const location: TabLocationType = .{
        .workspace = .{ .workspace = try workspace_module(1) },
        .tab_id = try tab_module(1),
    };
    const pane = try Pane.create(.{
        .io = io,
        .gpa = gpa,
        .history_service = &service,
        .graphics_budget = &budget,
    }, .{
        .identity = .{ .id = try pane_module(1), .generation = 1 },
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

    try std.testing.expect(try encodeNextGraphics(&attachment, .{ .buffer = &buffer, .global_credit = 4, .live_storage_available = true }) == null);
    support_module.processMediaTurn(pane);
    const payload = (try encodeNextGraphics(&attachment, .{ .buffer = &buffer, .global_credit = 4, .live_storage_available = true })).?;
    try std.testing.expect((try decodeServer_module(payload)) == .graphics_image);
    try std.testing.expectEqual(@as(usize, 0), attachment.graphics.credit);
    try std.testing.expect(attachment.graphics.transfer != null);
}

test "a staged transfer drains while the media actor stays busy" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var service = try ServiceType.init(gpa, .{ .database_path = ":memory:" });
    defer {
        service.stop(io);
        service.deinit(io);
    }
    var budget = GraphicsBudget.init(max_image_bytes_global_module);
    const args = [_][*:0]const u8{ "/bin/sleep", "600" };
    const command = try CommandType.fromArgv(&args);
    const location: TabLocationType = .{
        .workspace = .{ .workspace = try workspace_module(1) },
        .tab_id = try tab_module(1),
    };
    const pane = try Pane.create(.{
        .io = io,
        .gpa = gpa,
        .history_service = &service,
        .graphics_budget = &budget,
    }, .{
        .identity = .{ .id = try pane_module(1), .generation = 1 },
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
    const credit = max_image_bytes_global_module;

    // Staging refuses to outrun the snapshot begin, which resets the state
    // it would have written.
    try std.testing.expectEqual(StageResult.idle, try stageNextTransfer(&attachment, credit));
    try std.testing.expect((try decodeServer_module(
        (try encodeNextGraphics(&attachment, .{ .buffer = &buffer, .global_credit = credit, .live_storage_available = true })).?,
    )) == .graphics_snapshot);

    // The media actor prepares the copy; runtime staging only adopts it.
    try std.testing.expectEqual(StageResult.blocked, try stageNextTransfer(&attachment, credit));
    support_module.processMediaTurn(pane);
    try std.testing.expectEqual(StageResult.staged, try stageNextTransfer(&attachment, credit));
    try std.testing.expect(attachment.graphics.transfer != null);
    try std.testing.expect((try decodeServer_module(
        (try encodeNextGraphics(&attachment, .{ .buffer = &buffer, .global_credit = credit, .live_storage_available = false })).?,
    )) == .graphics_image);
    try std.testing.expect((try decodeServer_module(
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
        const message = try decodeServer_module(payload);
        if (message == .graphics_snapshot and message.graphics_snapshot.phase == .end) {
            closed = true;
        }
    }
    try std.testing.expect(closed);
    try std.testing.expectEqual(pane.graphics_revision, attachment.graphics.observed_revision);
}

test "completed replacements do not exhaust attachment image slots" {
    var attachment: Attachment = undefined;
    attachment.graphics.known_images =
        [_]?KnownImageType{null} ** max_images_per_pane_module;

    const replacements = max_images_per_pane_module * 2;
    for (1..replacements + 1) |generation| {
        const key: ImageKeyType = .{
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
    var service = try ServiceType.init(gpa, .{ .database_path = ":memory:" });
    defer {
        service.stop(io);
        service.deinit(io);
    }
    var budget = GraphicsBudget.init(max_image_bytes_global_module);
    const args = [_][*:0]const u8{ "/bin/sleep", "600" };
    const command = try CommandType.fromArgv(&args);
    const location: TabLocationType = .{
        .workspace = .{ .workspace = try workspace_module(1) },
        .tab_id = try tab_module(1),
    };
    const pane = try Pane.create(.{
        .io = io,
        .gpa = gpa,
        .history_service = &service,
        .graphics_budget = &budget,
    }, .{
        .identity = .{ .id = try pane_module(1), .generation = 1 },
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
    if (comptime !shared_transfer.shared_memory_supported) {
        return error.SkipZigTest;
    }
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var service = try ServiceType.init(gpa, .{ .database_path = ":memory:" });
    defer {
        service.stop(io);
        service.deinit(io);
    }
    var budget = GraphicsBudget.init(max_image_bytes_global_module);
    const args = [_][*:0]const u8{ "/bin/sleep", "600" };
    const command = try CommandType.fromArgv(&args);
    const location: TabLocationType = .{
        .workspace = .{ .workspace = try workspace_module(1) },
        .tab_id = try tab_module(1),
    };
    const pane = try Pane.create(.{
        .io = io,
        .gpa = gpa,
        .history_service = &service,
        .graphics_budget = &budget,
    }, .{
        .identity = .{ .id = try pane_module(1), .generation = 1 },
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
    try std.testing.expect((try decodeServer_module(
        (try encodeNextGraphics(&attachment, .{ .buffer = &buffer, .global_credit = max_image_bytes_global_module, .live_storage_available = true })).?,
    )) == .graphics_snapshot);
    try std.testing.expect(try encodeNextGraphics(&attachment, .{ .buffer = &buffer, .global_credit = max_image_bytes_global_module, .live_storage_available = true }) == null);
    support_module.processMediaTurn(pane);
    const message = (try decodeServer_module(
        (try encodeNextGraphics(&attachment, .{ .buffer = &buffer, .global_credit = max_image_bytes_global_module, .live_storage_available = true })).?,
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
    while (try encodeNextGraphics(&attachment, .{ .buffer = &buffer, .global_credit = max_image_bytes_global_module, .live_storage_available = true })) |payload| {
        try std.testing.expect((try decodeServer_module(payload)) != .graphics_image_chunk);
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
    if (comptime !shared_transfer.shared_memory_supported) {
        return error.SkipZigTest;
    }
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var service = try ServiceType.init(gpa, .{ .database_path = ":memory:" });
    defer {
        service.stop(io);
        service.deinit(io);
    }
    var budget = GraphicsBudget.init(max_image_bytes_global_module);
    const args = [_][*:0]const u8{ "/bin/sleep", "600" };
    const command = try CommandType.fromArgv(&args);
    const location: TabLocationType = .{
        .workspace = .{ .workspace = try workspace_module(1) },
        .tab_id = try tab_module(1),
    };
    const pane = try Pane.create(.{
        .io = io,
        .gpa = gpa,
        .history_service = &service,
        .graphics_budget = &budget,
    }, .{
        .identity = .{ .id = try pane_module(2), .generation = 1 },
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

    const name = shared_transfer.freezeSharedPixels(&[_]u8{ 1, 2, 3, 255 }).?;
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
