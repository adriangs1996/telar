const StatsType = @import("Stats.zig");
const delivery = @import("kitty_delivery.zig");
const LayoutSnapshot = @import("telar-client").LayoutSnapshot;
const kitty_codec = @import("kitty_codec.zig");
const std = @import("std");
const kitty = @import("kitty.zig");
const writeTransmissionAbort_module = @import("kitty_protocol").writeTransmissionAbort;
const writeDeleteImage_module = @import("kitty_protocol").writeDeleteImage;
const writeDeleteImageRange_module = @import("kitty_protocol").writeDeleteImageRange;
const writeDeletePlacement_module = @import("kitty_protocol").writeDeletePlacement;
const identity_module = @import("telar-client").identity;
const FallbackFrame = @import("FallbackFrame.zig");
const PlacementIdentityType = @import("telar-client").PlacementIdentity;
const PlacementGeometry = @import("PlacementGeometry.zig");
const OutputPlacementType = @import("kitty_protocol").OutputPlacement;
const RectType = @import("telar-core").RectRect;
const clipScaled_module = @import("telar-core").clipScaled;
const KittyGraphicsWriter = @This();

store: *delivery.Store,
layout_snapshot: *const LayoutSnapshot,
cell_width: u16,
cell_height: u16,
/// Encoded-byte budget for this pass. The client boosts it while host
/// input is idle; the default protects the keystroke echo.
budget: usize = kitty_codec.transmission_budget_per_frame,
/// Emission counts accumulated across this writer's passes; the client
/// folds them into its telemetry after each flush.
stats: StatsType = .{},
/// Monotonic time of this pass, for retire latency. Zero disables it.
now_ns: u64 = 0,
/// Which escapes this pass may emit. `control` rides inside a cell frame
/// and therefore never streams pixels; `bulk` is the paced media pass.
mode: Mode = .bulk,

pub const Mode = enum {
    /// Shared names, placements and deletes: a few hundred bytes per
    /// image, so they fit the synchronized cell update without delaying
    /// it. Images that need inline pixels stay damaged for `bulk`.
    control,
    /// Everything the byte budget allows, chunked transfers included.
    bulk,
};

pub const Stats = @import("Stats.zig");

pub fn writeOpaque(context: *anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!usize {
    const self: *KittyGraphicsWriter = @ptrCast(@alignCast(context));
    return self.write(writer);
}

pub fn write(self: *KittyGraphicsWriter, writer: *std.Io.Writer) std.Io.Writer.Error!usize {
    delivery.beginPresentation(self.store, self.now_ns);
    if (!self.store.damage or self.cell_width == 0 or self.cell_height == 0) {
        return 0;
    }
    self.store.collectRetired(null, null);
    // An open chunked transfer owns the stream until the bulk pass closes
    // it; a control pass may not even emit a delete in between.
    if (self.mode == .control and self.store.delivery.partial != null) {
        return 0;
    }
    var written: usize = 0;
    var budget: usize = self.budget;
    var compress_budget: usize = kitty.compression_slice_per_frame;
    var compressing = false;
    var bulk_pending = false;

    // An open chunked transfer owns the graphics stream: the protocol
    // forbids other graphics escapes between its chunks, so it either
    // resumes first or is closed before anything else is emitted.
    if (self.store.delivery.partial) |partial| {
        const alive = if (self.store.images.getPtr(partial.key)) |entry|
            entry.delivery.external_id == partial.external_id
        else
            false;
        if (!alive) {
            // The image was replaced or deleted mid-transfer. An empty
            // final chunk closes the stream; the length mismatch makes
            // the terminal discard it, silently under q=2.
            written += try writeTransmissionAbort_module(writer);
            written += try writeDeleteImage_module(writer, partial.external_id);
            self.store.delivery.partial = null;
        } else {
            const entry = self.store.images.getPtr(partial.key).?;
            // The open transfer's header already declared its encoding,
            // so the resume reads the buffer that header described.
            const source = if (partial.compressed) entry.delivery.compressed.? else entry.pixels;
            self.stats.transmission_passes += 1;
            const progress = try kitty_codec.writeTransmissionChunks(writer, .{
                .external_id = partial.external_id,
                .image = entry.metadata,
                .pixels = source,
                .start_offset = partial.offset,
                .budget = budget,
                .compressed = partial.compressed,
            });
            written += progress.written;
            if (progress.offset < source.len) {
                self.store.delivery.partial.?.offset = progress.offset;
                // Damage stays set; the next frame resumes here.
                return written;
            }
            delivery.completeTransmission(self.store, entry, .inline_data);
            self.stats.inline_images += 1;
            self.stats.compressed_images += @intFromBool(partial.compressed);
            written += try self.writeFallbackPlacements(writer, .{ .partial = partial, .image = entry.* });
            self.store.collectRetired(
                partial.key.pane_id,
                partial.key.image_id,
            );
            budget -= @min(budget, progress.written);
        }
    }
    if (self.store.delivery.delete_overflow) {
        written += try writeDeleteImageRange_module(writer, 1, 0x3fffffff);
        delivery.recoverDeleteOverflow(self.store);
    }
    while (delivery.popDelete(self.store)) |deletion| written += switch (deletion) {
        .image => |image_id| try writeDeleteImage_module(writer, image_id),
        .placement => |placement| try writeDeletePlacement_module(
            writer,
            placement.image_id,
            placement.placement_id,
        ),
    };

    var images = self.store.images.iterator();
    while (images.next()) |entry| {
        if (!self.store.paneVisible(entry.key_ptr.pane_id)) {
            continue;
        }
        const image = entry.value_ptr;
        if (image.received != image.pixels.len or image.delivery.transmitted) {
            continue;
        }
        // Budget spent: the rest keeps its damage and waits for the next
        // frame, so no image can park itself in front of a keystroke.
        if (budget == 0) {
            return written;
        }
        if (image.shared) |*shared| {
            if (!image.delivery.force_direct and self.store.shared_memory) {
                const emitted = try kitty_codec.writeSharedTransmission(writer, .{
                    .external_id = image.delivery.external_id,
                    .image = image.metadata,
                    .name = shared.slice(),
                });
                written += emitted;
                delivery.completeTransmission(self.store, image, .shared_memory);
                self.stats.shared_images += 1;
                budget -= @min(budget, emitted);
                continue;
            }
        }
        if (self.mode == .control) {
            bulk_pending = true;
            continue;
        }
        // A still-deflating image keeps its wire budget for the others;
        // its own transmission starts once the stream is finished.
        const compress_budget_before = compress_budget;
        const source_ready = delivery.advanceCompression(self.store, image, &compress_budget);
        self.stats.compress_passes +=
            @intFromBool(compress_budget != compress_budget_before);
        if (!source_ready) {
            compressing = true;
            continue;
        }
        const compressed = image.delivery.compressed != null;
        const source = image.delivery.compressed orelse image.pixels;
        self.stats.transmission_passes += 1;
        const progress = try kitty_codec.writeTransmissionChunks(writer, .{
            .external_id = image.delivery.external_id,
            .image = image.metadata,
            .pixels = source,
            .start_offset = 0,
            .budget = budget,
            .compressed = compressed,
        });
        written += progress.written;
        if (progress.offset < source.len) {
            self.store.delivery.partial = .{
                .key = entry.key_ptr.*,
                .external_id = image.delivery.external_id,
                .offset = progress.offset,
                .compressed = compressed,
            };
            delivery.capturePartialPlacements(self.store);
            // The open transfer forbids emitting anything else.
            return written;
        }
        delivery.completeTransmission(self.store, image, .inline_data);
        self.stats.inline_images += 1;
        self.stats.compressed_images += @intFromBool(compressed);
        budget -= @min(budget, progress.written);
    }

    var placements = self.store.placements.iterator();
    while (placements.next()) |entry| {
        if (!self.store.paneVisible(entry.key_ptr.pane_id)) {
            continue;
        }
        const placement = entry.value_ptr;
        if (!placement.delivery.dirty) {
            continue;
        }
        const image = self.store.images.get(identity_module(
            entry.key_ptr.pane_id,
            placement.placement.key,
        )) orelse continue;
        if (!image.delivery.transmitted) {
            continue;
        }
        const output = self.geometry(.{
            .pane_id = entry.key_ptr.pane_id,
            .placement = placement.placement,
            .image = image.metadata,
        }) orelse {
            if (placement.delivery.emitted_image_id) |previous_image_id| {
                written += try writeDeletePlacement_module(
                    writer,
                    previous_image_id,
                    placement.delivery.external_id,
                );
            }
            placement.delivery.emitted_image_id = null;
            placement.delivery.dirty = false;
            self.store.collectRetired(
                entry.key_ptr.pane_id,
                placement.placement.key.image_id,
            );
            continue;
        };
        written += try kitty_codec.writePlacement(writer, .{
            .image_id = image.delivery.external_id,
            .placement_id = placement.delivery.external_id,
            .value = output,
            .z = placement.placement.z_index,
        });
        if (placement.delivery.emitted_image_id) |previous_image_id| {
            if (previous_image_id != image.delivery.external_id) {
                written += try writeDeletePlacement_module(
                    writer,
                    previous_image_id,
                    placement.delivery.external_id,
                );
            }
        }
        placement.delivery.emitted_image_id = image.delivery.external_id;
        placement.delivery.dirty = false;
        self.store.collectRetired(
            entry.key_ptr.pane_id,
            placement.placement.key.image_id,
        );
    }
    self.store.damage = bulk_pending or compressing or self.store.delivery.delete_len != 0 or
        self.store.delivery.delete_overflow or delivery.hasPendingSharedRelease(self.store);
    return written;
}

/// Presents a completed frame even if a newer generation arrived while
/// it crossed the host terminal. This bounds the queue to the visible,
/// in-flight and latest generations without starving continuous repaint.
fn writeFallbackPlacements(self: *KittyGraphicsWriter, writer: *std.Io.Writer, frame: FallbackFrame) std.Io.Writer.Error!usize {
    if (!self.store.paneVisible(frame.partial.key.pane_id)) {
        return 0;
    }
    var written: usize = 0;
    for (frame.partial.fallbacks[0..frame.partial.fallback_count]) |fallback| {
        const key: PlacementIdentityType = .{
            .pane_id = frame.partial.key.pane_id,
            .virtual_id = fallback.placement.virtual_id,
        };
        const placement = self.store.placements.getPtr(key) orelse continue;
        if (placement.delivery.external_id != fallback.external_id or
            placement.placement.key.image_id != frame.partial.key.image_id or
            placement.placement.key.generation < frame.partial.key.generation)
        {
            continue;
        }
        const output = self.geometry(.{
            .pane_id = frame.partial.key.pane_id,
            .placement = fallback.placement,
            .image = frame.image.metadata,
        }) orelse continue;
        written += try kitty_codec.writePlacement(writer, .{
            .image_id = frame.image.delivery.external_id,
            .placement_id = placement.delivery.external_id,
            .value = output,
            .z = fallback.placement.z_index,
        });
        if (placement.delivery.emitted_image_id) |previous_image_id| {
            if (previous_image_id != frame.image.delivery.external_id) {
                written += try writeDeletePlacement_module(
                    writer,
                    previous_image_id,
                    placement.delivery.external_id,
                );
            }
        }
        placement.delivery.emitted_image_id = frame.image.delivery.external_id;
        placement.delivery.dirty = !std.meta.eql(placement.placement, fallback.placement);
    }
    return written;
}

fn geometry(self: *const KittyGraphicsWriter, geometry_input: PlacementGeometry) ?OutputPlacementType {
    const view = self.layout_snapshot.find(geometry_input.pane_id) orelse return null;
    const source = geometry_input.placement.sourceRect(geometry_input.image) catch return null;
    const source_width: u32 = @intCast(source.width);
    const source_height: u32 = @intCast(source.height);
    const width, const height = kitty.destinationSize(.{
        .placement = geometry_input.placement,
        .source_width = source_width,
        .source_height = source_height,
        .cell_width = self.cell_width,
        .cell_height = self.cell_height,
    });
    if (width == 0 or height == 0) {
        return null;
    }
    const destination: RectType = .{
        .x = (@as(i64, view.content.x) + geometry_input.placement.x) * self.cell_width + geometry_input.placement.offset_x,
        .y = (@as(i64, view.content.y) + geometry_input.placement.y) * self.cell_height + geometry_input.placement.offset_y,
        .width = width,
        .height = height,
    };
    const bounds: RectType = .{
        .x = @as(i64, view.content.x) * self.cell_width,
        .y = @as(i64, view.content.y) * self.cell_height,
        .width = @as(u64, view.content.w) * self.cell_width,
        .height = @as(u64, view.content.h) * self.cell_height,
    };
    const clipped = clipScaled_module(destination, .{
        .x = source.x,
        .y = source.y,
        .width = source_width,
        .height = source_height,
    }, bounds) orelse return null;
    const pixel_x: u64 = @intCast(clipped.destination.x);
    const pixel_y: u64 = @intCast(clipped.destination.y);
    return .{
        .column = @intCast(pixel_x / self.cell_width),
        .row = @intCast(pixel_y / self.cell_height),
        .offset_x = @intCast(pixel_x % self.cell_width),
        .offset_y = @intCast(pixel_y % self.cell_height),
        .source_x = @intCast(clipped.source.x),
        .source_y = @intCast(clipped.source.y),
        .source_width = @intCast(clipped.source.width),
        .source_height = @intCast(clipped.source.height),
        .columns = @intCast(std.math.divCeil(u64, clipped.destination.width + pixel_x % self.cell_width, self.cell_width) catch 1),
        .rows = @intCast(std.math.divCeil(u64, clipped.destination.height + pixel_y % self.cell_height, self.cell_height) catch 1),
    };
}
