//! Kitty graphics delivery backed by the shared client resource catalog.

const resources = @import("telar-client").graphics;

const std = @import("std");
const native = @cImport({
    @cInclude("sys/stat.h");
});
const codec = @import("kitty_codec.zig");
const sidebar = @import("kitty_sidebar.zig");
pub const transmission_budget_per_frame = codec.transmission_budget_per_frame;
pub const OutputPlacement = codec.OutputPlacement;
pub const ChunkProgress = codec.ChunkProgress;
pub const TransmissionChunks = codec.TransmissionChunks;
pub const PngTransmissionChunks = codec.PngTransmissionChunks;
pub const Transmission = codec.Transmission;
pub const SharedTransmission = codec.SharedTransmission;
pub const writeTransmissionChunks = codec.writeTransmissionChunks;
pub const writePngTransmissionChunks = codec.writePngTransmissionChunks;
pub const writeTransmission = codec.writeTransmission;
pub const writeSharedTransmission = codec.writeSharedTransmission;
pub const writeTransmissionAbort = codec.writeTransmissionAbort;
pub const PlacementCommand = codec.PlacementCommand;
pub const writePlacement = codec.writePlacement;
pub const writeUiPlacement = codec.writeUiPlacement;
pub const writeDeleteImage = codec.writeDeleteImage;
pub const writeDeletePlacement = codec.writeDeletePlacement;
pub const writeDeleteImageRange = codec.writeDeleteImageRange;
pub const SidebarProvider = sidebar.SidebarProvider;
pub const SidebarProviderPlacement = sidebar.SidebarProviderPlacement;
pub const SidebarFocus = sidebar.SidebarFocus;
pub const SidebarContent = sidebar.SidebarContent;
pub const CellSize = sidebar.CellSize;
pub const KittySidebarRenderer = sidebar.KittySidebarRenderer;

const builtin = @import("builtin");
const core = @import("telar-core");
const workspace = @import("../workspace/root.zig");
const layout = workspace.layout;
const multiplexer = workspace.multiplexer;
const capability_mod = @import("capabilities.zig");

const Io = std.Io;
const diagnostics = core.diagnostics;
const schema = core.schema;
const graphics = core.graphics;

pub const supportsSharedMemory = resources.supportsSharedMemory;

/// Whether this client build can map POSIX shared memory the runtime names.
/// The client declares it to the runtime explicitly; nothing is assumed.
pub fn clientSupportsSharedMemory() bool {
    return supportsSharedMemory();
}

pub const query_image_id = capability_mod.query_image_id;
pub const zlib_query_image_id = capability_mod.zlib_query_image_id;
pub const capability_timeout_ns = capability_mod.timeout_ns;
pub const capability_query = capability_mod.query;
pub const Support = capability_mod.Support;
pub const SidebarRendering = capability_mod.SidebarRendering;
pub const ResolvedSidebarRendering = capability_mod.ResolvedSidebarRendering;

pub const Configuration = struct {
    support: Support,
    cell_width: u16,
    cell_height: u16,
};

/// Encoded image bytes one media pass may put on the direct-data fallback
/// wire. Local Ghostty sessions use a compact shared-memory command instead.
/// Raw pixel bytes one frame may push through the zlib deflater before an
/// inline transmission. Bounds the writer's compression work per pass to
/// about two milliseconds at the ~300 MiB/s a `.fastest` deflate measures.
pub const compression_slice_per_frame: usize = 512 * 1024;
/// Below this raw size the o=z probe, header, and deflate overhead outweigh
/// the saved wire bytes.
pub const compression_min_bytes: usize = 8 * 1024;

pub const ImageIdentity = resources.ImageIdentity;

pub const PlacementIdentity = resources.PlacementIdentity;

pub const SharedPixels = resources.SharedPixels;

pub const PixelAllocation = resources.PixelAllocation;

/// In-progress deflate of one image's pixels. Heap-allocated and never moved,
/// because the compressor holds pointers into the allocating writer and the
/// window buffer.
pub const Compression = struct {
    input: []u8 = &.{},
    input_len: usize = 0,
    finish_after: bool = false,
    failed: bool = false,
    allocating: Io.Writer.Allocating,
    window: [std.compress.flate.max_window_len]u8,
    compress: std.compress.flate.Compress,
    offset: usize,

    /// Compresses only copied input; no store, image or mutable model is borrowed.
    /// Example: `const completed = Compression.run(job);`.
    pub fn run(job: *Compression) *Compression {
        job.compress.writer.writeAll(job.input[0..job.input_len]) catch {
            job.failed = true;
            return job;
        };
        if (job.finish_after) {
            job.compress.finish() catch {
                job.failed = true;
            };
        }

        return job;
    }
};

pub const CompressionScheduler = struct {
    context: *anyopaque,
    start: *const fn (*anyopaque, *Compression) anyerror!void,
};

pub const ImageEntry = Store.ImageEntry;

/// Writer passes a host may sit on a shared name before the client reclaims
/// the object and falls back to inline transmission. Roughly three seconds
/// at the 60Hz pace: far beyond a healthy Ghostty, short enough that a host
/// that ignored the name cannot pin pane memory credit forever.
pub const shared_consume_deadline_passes: u64 = 180;
/// Consecutive expiries after which the host is deemed unable to consume
/// shared names at all and every image goes back to inline transmission.
pub const shared_expiry_disable_threshold: u8 = 2;

pub const PlacementEntry = Store.PlacementEntry;

pub const Delete = union(enum) {
    image: u32,
    placement: struct { image_id: u32, placement_id: u32 },
};

const FallbackPlacement = struct {
    placement: graphics.Placement,
    external_id: u32,
};

pub const PartialPlacement = struct {
    pane_id: schema.PaneId,
    placement: graphics.Placement,
    external_id: u32,
};

/// A chunked transfer the frame budget interrupted. The next frame resumes
/// it before emitting any other graphics escape, which the protocol demands.
pub const PartialTransmission = struct {
    key: ImageIdentity,
    external_id: u32,
    offset: usize,
    /// The open transfer streams the entry's compressed bytes, so a resume
    /// must keep reading the same buffer the header's `o=z` promised.
    compressed: bool = false,
    fallback_count: usize = 0,
    fallbacks: [graphics.max_placements_per_pane]FallbackPlacement = undefined,
};

const FallbackFrame = struct {
    partial: PartialTransmission,
    image: ImageEntry,
};

const PlacementGeometry = struct {
    pane_id: schema.PaneId,
    placement: graphics.Placement,
    image: graphics.Image,
};

pub const delivery = @import("kitty_delivery.zig");
pub const Store = delivery.Store;

pub const identity = resources.identity;

pub const KittyGraphicsWriter = struct {
    store: *Store,
    layout_snapshot: *const layout.Snapshot,
    cell_width: u16,
    cell_height: u16,
    /// Encoded-byte budget for this pass. The client boosts it while host
    /// input is idle; the default protects the keystroke echo.
    budget: usize = transmission_budget_per_frame,
    /// Emission counts accumulated across this writer's passes; the client
    /// folds them into its telemetry after each flush.
    stats: Stats = .{},
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

    pub const Stats = struct {
        /// Images handed to the host as a shared-memory name.
        shared_images: u64 = 0,
        /// Images whose inline transmission closed, compressed or raw.
        inline_images: u64 = 0,
        /// The subset of `inline_images` that shipped as a zlib stream.
        compressed_images: u64 = 0,
        /// Chunk-emission calls; divided by `inline_images` this is the
        /// passes-per-image pacing the budget policy produces.
        transmission_passes: u64 = 0,
        /// Passes that advanced a deflate by at least one slice.
        compress_passes: u64 = 0,
    };

    pub fn writeOpaque(context: *anyopaque, writer: *Io.Writer) Io.Writer.Error!usize {
        const self: *KittyGraphicsWriter = @ptrCast(@alignCast(context));
        return self.write(writer);
    }

    pub fn write(self: *KittyGraphicsWriter, writer: *Io.Writer) Io.Writer.Error!usize {
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
        var compress_budget: usize = compression_slice_per_frame;
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
                written += try writeTransmissionAbort(writer);
                written += try writeDeleteImage(writer, partial.external_id);
                self.store.delivery.partial = null;
            } else {
                const entry = self.store.images.getPtr(partial.key).?;
                // The open transfer's header already declared its encoding,
                // so the resume reads the buffer that header described.
                const source = if (partial.compressed) entry.delivery.compressed.? else entry.pixels;
                self.stats.transmission_passes += 1;
                const progress = try writeTransmissionChunks(writer, .{
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
            written += try writeDeleteImageRange(writer, 1, 0x3fffffff);
            delivery.recoverDeleteOverflow(self.store);
        }
        while (delivery.popDelete(self.store)) |deletion| written += switch (deletion) {
            .image => |image_id| try writeDeleteImage(writer, image_id),
            .placement => |placement| try writeDeletePlacement(
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
                    const emitted = try writeSharedTransmission(writer, .{
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
            const progress = try writeTransmissionChunks(writer, .{
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
            const image = self.store.images.get(identity(
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
                    written += try writeDeletePlacement(
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
            written += try writePlacement(writer, .{
                .image_id = image.delivery.external_id,
                .placement_id = placement.delivery.external_id,
                .value = output,
                .z = placement.placement.z_index,
            });
            if (placement.delivery.emitted_image_id) |previous_image_id| {
                if (previous_image_id != image.delivery.external_id) {
                    written += try writeDeletePlacement(
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
    fn writeFallbackPlacements(self: *KittyGraphicsWriter, writer: *Io.Writer, frame: FallbackFrame) Io.Writer.Error!usize {
        if (!self.store.paneVisible(frame.partial.key.pane_id)) {
            return 0;
        }
        var written: usize = 0;
        for (frame.partial.fallbacks[0..frame.partial.fallback_count]) |fallback| {
            const key: PlacementIdentity = .{
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
            written += try writePlacement(writer, .{
                .image_id = frame.image.delivery.external_id,
                .placement_id = placement.delivery.external_id,
                .value = output,
                .z = fallback.placement.z_index,
            });
            if (placement.delivery.emitted_image_id) |previous_image_id| {
                if (previous_image_id != frame.image.delivery.external_id) {
                    written += try writeDeletePlacement(
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

    fn geometry(self: *const KittyGraphicsWriter, geometry_input: PlacementGeometry) ?OutputPlacement {
        const view = self.layout_snapshot.find(geometry_input.pane_id) orelse return null;
        const source = geometry_input.placement.sourceRect(geometry_input.image) catch return null;
        const source_width: u32 = @intCast(source.width);
        const source_height: u32 = @intCast(source.height);
        const width, const height = destinationSize(.{
            .placement = geometry_input.placement,
            .source_width = source_width,
            .source_height = source_height,
            .cell_width = self.cell_width,
            .cell_height = self.cell_height,
        });
        if (width == 0 or height == 0) {
            return null;
        }
        const destination: graphics.Rect = .{
            .x = (@as(i64, view.content.x) + geometry_input.placement.x) * self.cell_width + geometry_input.placement.offset_x,
            .y = (@as(i64, view.content.y) + geometry_input.placement.y) * self.cell_height + geometry_input.placement.offset_y,
            .width = width,
            .height = height,
        };
        const bounds: graphics.Rect = .{
            .x = @as(i64, view.content.x) * self.cell_width,
            .y = @as(i64, view.content.y) * self.cell_height,
            .width = @as(u64, view.content.w) * self.cell_width,
            .height = @as(u64, view.content.h) * self.cell_height,
        };
        const clipped = graphics.clipScaled(destination, .{
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
};

const DestinationSizeInput = struct {
    placement: graphics.Placement,
    source_width: u32,
    source_height: u32,
    cell_width: u16,
    cell_height: u16,
};

fn destinationSize(size_input: DestinationSizeInput) struct { u64, u64 } {
    if (size_input.placement.columns == 0 and size_input.placement.rows == 0) {
        return .{ size_input.source_width, size_input.source_height };
    }
    if (size_input.placement.columns != 0 and size_input.placement.rows != 0) {
        return .{
            @as(u64, size_input.placement.columns) * size_input.cell_width -| size_input.placement.offset_x,
            @as(u64, size_input.placement.rows) * size_input.cell_height -| size_input.placement.offset_y,
        };
    }
    if (size_input.placement.columns != 0) {
        const width = @as(u64, size_input.placement.columns) * size_input.cell_width -| size_input.placement.offset_x;
        return .{ width, width * size_input.source_height / size_input.source_width };
    }
    const height = @as(u64, size_input.placement.rows) * size_input.cell_height -| size_input.placement.offset_y;
    return .{ height * size_input.source_width / size_input.source_height, height };
}

test "capability query and probe identities are exact" {
    try std.testing.expectEqualStrings(
        "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\" ++
            "\x1b_Gi=32,s=1,v=1,a=q,t=d,f=24,o=z;eJxjYGAAAAADAAE=\x1b\\" ++
            "\x1b[14t\x1b[16t\x1b[?1016$p\x1b[c",
        capability_query,
    );
    try std.testing.expectEqual(@as(u32, 31), query_image_id);
    try std.testing.expectEqual(@as(u32, 32), zlib_query_image_id);
}

test "automatic sidebar renderer falls back while capability is absent" {
    try std.testing.expectEqual(ResolvedSidebarRendering.cells, try SidebarRendering.automatic.resolve(.unknown));
    try std.testing.expectEqual(ResolvedSidebarRendering.cells, try SidebarRendering.automatic.resolve(.unsupported));
    try std.testing.expectEqual(ResolvedSidebarRendering.kitty_hybrid, try SidebarRendering.automatic.resolve(.supported));
    try std.testing.expectError(error.KittyGraphicsUnsupported, SidebarRendering.kitty_hybrid.resolve(.unsupported));
}

test "direct transmission chunks payload without changing pixels" {
    var pixels: [3073]u8 = undefined;
    for (&pixels, 0..) |*byte, index| byte.* = @truncate(index);
    var output: [8192]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    _ = try writeTransmission(&writer, .{
        .external_id = 9,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgba,
            .width = 3073,
            .height = 1,
            .byte_len = pixels.len,
        },
        .pixels = &pixels,
    });
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "\x1b_Ga=t,f=32,s=3073,v=1,t=d,i=9,q=2,m=1;"));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b\\\x1b_Gm=0;") != null);
}

test "exterior IDs do not collide across panes with identical child IDs" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const metadata: graphics.Image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    try store.applyImage(.{ .pane_id = @enumFromInt(1), .revision = 1, .image = metadata });
    try store.applyImage(.{ .pane_id = @enumFromInt(2), .revision = 1, .image = metadata });
    const first = store.images.get(identity(@enumFromInt(1), metadata.key)).?.delivery.external_id;
    const second = store.images.get(identity(@enumFromInt(2), metadata.key)).?.delivery.external_id;
    try std.testing.expect(first != second);
    try std.testing.expect(first < 0x40000000 and second < 0x40000000);
}

test "unchanged graphics emit no work and resize does not retransmit pixels" {
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 10, .rows = 5 } });

    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const metadata: graphics.Image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    try store.applyImage(.{ .pane_id = @enumFromInt(1), .revision = 1, .image = metadata });
    try store.applyChunk(.{
        .pane_id = @enumFromInt(1),
        .revision = 1,
        .key = metadata.key,
        .offset = 0,
        .bytes = &.{ 1, 2, 3, 255 },
    });
    try store.applyPlacement(.{
        .pane_id = @enumFromInt(1),
        .revision = 1,
        .placement = .{
            .key = metadata.key,
            .virtual_id = 1,
            .placement_id = 1,
            .x = 0,
            .y = 0,
        },
    });
    var first_bytes: [4096]u8 = undefined;
    var first_writer = Io.Writer.fixed(&first_bytes);
    const layout_snapshot = model.layoutSnapshot(.{ .w = 10, .h = 5 });
    var graphics_writer: KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = layout_snapshot,
        .cell_width = 10,
        .cell_height = 20,
    };
    try std.testing.expect((try graphics_writer.write(&first_writer)) != 0);
    try std.testing.expect(std.mem.indexOf(u8, first_writer.buffered(), "a=t") != null);

    var idle_bytes: [64]u8 = undefined;
    var idle_writer = Io.Writer.fixed(&idle_bytes);
    try std.testing.expectEqual(@as(usize, 0), try graphics_writer.write(&idle_writer));

    delivery.invalidatePlacements(&store);
    var resize_bytes: [1024]u8 = undefined;
    var resize_writer = Io.Writer.fixed(&resize_bytes);
    try std.testing.expect((try graphics_writer.write(&resize_writer)) != 0);
    try std.testing.expect(std.mem.indexOf(u8, resize_writer.buffered(), "a=p") != null);
    try std.testing.expect(std.mem.indexOf(u8, resize_writer.buffered(), "a=t") == null);

    try store.setPaneVisible(@enumFromInt(1), false);
    var hidden_bytes: [1024]u8 = undefined;
    var hidden_writer = Io.Writer.fixed(&hidden_bytes);
    try std.testing.expect((try graphics_writer.write(&hidden_writer)) != 0);
    try std.testing.expect(std.mem.indexOf(u8, hidden_writer.buffered(), "a=d") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_writer.buffered(), "a=t") == null);

    try store.setPaneVisible(@enumFromInt(1), true);
    var visible_bytes: [1024]u8 = undefined;
    var visible_writer = Io.Writer.fixed(&visible_bytes);
    try std.testing.expect((try graphics_writer.write(&visible_writer)) != 0);
    try std.testing.expect(std.mem.indexOf(u8, visible_writer.buffered(), "a=p") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible_writer.buffered(), "a=t") == null);
}

test "image transmission is paced across frames by the byte budget" {
    // Regression: the writer base64-encoded whole images inside one frame's
    // flush, so a large child image sat between a keystroke and its echo.
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 10, .rows = 5 } });

    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const metadata: graphics.Image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgba,
        .width = 512,
        .height = 256,
        .byte_len = 512 * 256 * 4,
    };
    const pixels = try std.testing.allocator.alloc(u8, 512 * 256 * 4);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 0xab);
    try store.applyImage(.{ .pane_id = @enumFromInt(1), .revision = 1, .image = metadata });
    try store.applyChunk(.{
        .pane_id = @enumFromInt(1),
        .revision = 1,
        .key = metadata.key,
        .offset = 0,
        .bytes = pixels,
    });
    try store.applyPlacement(.{
        .pane_id = @enumFromInt(1),
        .revision = 1,
        .placement = .{
            .key = metadata.key,
            .virtual_id = 1,
            .placement_id = 1,
            .x = 0,
            .y = 0,
        },
    });

    const layout_snapshot = model.layoutSnapshot(.{ .w = 10, .h = 5 });
    var graphics_writer: KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = layout_snapshot,
        .cell_width = 10,
        .cell_height = 20,
    };
    const frame_buffer = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(frame_buffer);

    // One frame spends at most the budget plus one chunk of overshoot.
    var writer = Io.Writer.fixed(frame_buffer);
    const first = try graphics_writer.write(&writer);
    try std.testing.expect(first <= transmission_budget_per_frame + 8192);

    var frames: usize = 1;
    var placed = false;
    while (store.damage) {
        frames += 1;
        try std.testing.expect(frames < 32);
        var next = Io.Writer.fixed(frame_buffer);
        _ = try graphics_writer.write(&next);
        if (std.mem.indexOf(u8, next.buffered(), "a=p") != null) {
            placed = true;
        }
    }
    try std.testing.expect(frames > 1);
    try std.testing.expect(placed);

    // Idle afterwards: no work left.
    var idle = Io.Writer.fixed(frame_buffer);
    try std.testing.expectEqual(@as(usize, 0), try graphics_writer.write(&idle));
}

/// One pane holding a complete 512x256 RGBA image with one placement, the
/// shape the budget and compression tests all exercise.
const TransmissionFixture = struct {
    const metadata: graphics.Image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgba,
        .width = 512,
        .height = 256,
        .byte_len = 512 * 256 * 4,
    };

    model: multiplexer.Model,
    store: Store,

    fn init(pixels: []const u8) !TransmissionFixture {
        std.debug.assert(pixels.len == metadata.byte_len);
        const location: schema.TabLocation = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        };
        var model = multiplexer.Model.init(std.testing.allocator);
        errdefer model.deinit();
        try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 10, .rows = 5 } });
        var store = Store.init(std.testing.allocator);
        errdefer store.deinit();
        try store.applyImage(.{ .pane_id = @enumFromInt(1), .revision = 1, .image = metadata });
        try store.applyChunk(.{
            .pane_id = @enumFromInt(1),
            .revision = 1,
            .key = metadata.key,
            .offset = 0,
            .bytes = pixels,
        });
        try store.applyPlacement(.{
            .pane_id = @enumFromInt(1),
            .revision = 1,
            .placement = .{
                .key = metadata.key,
                .virtual_id = 1,
                .placement_id = 1,
                .x = 0,
                .y = 0,
            },
        });
        return .{ .model = model, .store = store };
    }

    fn deinit(fixture: *TransmissionFixture) void {
        fixture.store.deinit();
        fixture.model.deinit();
    }

    fn writer(fixture: *TransmissionFixture, budget: usize) KittyGraphicsWriter {
        return .{
            .store = &fixture.store,
            .layout_snapshot = fixture.model.layoutSnapshot(.{ .w = 10, .h = 5 }),
            .cell_width = 10,
            .cell_height = 20,
            .budget = budget,
        };
    }
};

/// Concatenates the base64-decoded payloads of every `a=t` transmission and
/// `m=` continuation chunk in `bytes`, in stream order.
fn decodeTransmissionPayloads(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var collected: Io.Writer.Allocating = .init(gpa);
    defer collected.deinit();
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, search, "\x1b_G")) |start| {
        const end = std.mem.indexOfPos(u8, bytes, start, "\x1b\\") orelse break;
        search = end + 2;
        const body = bytes[start + 3 .. end];
        const separator = std.mem.indexOfScalar(u8, body, ';') orelse continue;
        const control = body[0..separator];
        if (std.mem.indexOf(u8, control, "a=t") == null and
            !std.mem.startsWith(u8, control, "m="))
        {
            continue;
        }
        const encoded = body[separator + 1 ..];
        const Decoder = std.base64.standard.Decoder;
        var decoded: [4096]u8 = undefined;
        const decoded_len = try Decoder.calcSizeForSlice(encoded);
        try Decoder.decode(decoded[0..decoded_len], encoded);
        try collected.writer.writeAll(decoded[0..decoded_len]);
    }
    return collected.toOwnedSlice();
}

fn inflateExact(gpa: std.mem.Allocator, compressed: []const u8, expected_len: usize) ![]u8 {
    var input = std.Io.Reader.fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&input, .zlib, &window);
    const inflated = try gpa.alloc(u8, expected_len);
    errdefer gpa.free(inflated);
    const inflated_len = try decompress.reader.readSliceShort(inflated);
    try std.testing.expectEqual(expected_len, inflated_len);
    return inflated;
}

test "a large explicit budget transmits and places a frame in one pass" {
    const pixels = try std.testing.allocator.alloc(u8, TransmissionFixture.metadata.byte_len);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 0xab);
    var fixture = try TransmissionFixture.init(pixels);
    defer fixture.deinit();

    var graphics_writer = fixture.writer(transmission_budget_per_frame * 8);
    const frame_buffer = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(frame_buffer);
    var writer = Io.Writer.fixed(frame_buffer);
    _ = try graphics_writer.write(&writer);

    // The whole image and its placement went out because this test explicitly
    // supplied enough budget for one pass.
    try std.testing.expect(fixture.store.delivery.partial == null);
    try std.testing.expect(!fixture.store.damage);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "a=p") != null);
    try std.testing.expectEqual(@as(u64, 1), graphics_writer.stats.inline_images);
    try std.testing.expectEqual(@as(u64, 1), graphics_writer.stats.transmission_passes);
    try std.testing.expectEqual(@as(u64, 0), graphics_writer.stats.compressed_images);
}

test "performance probe measures compression work outside the presentation turn" {
    const pixels = try std.testing.allocator.alloc(u8, TransmissionFixture.metadata.byte_len);
    defer std.testing.allocator.free(pixels);
    var prng = std.Random.DefaultPrng.init(9);
    for (pixels, 0..) |*byte, index| {
        byte.* = if (index % 16 == 3) prng.random().int(u8) else 0x30;
    }
    var turns: [20]u64 = undefined;
    var totals: [20]u64 = undefined;
    for (&turns, &totals) |*turn, *total| {
        var fixture = try TransmissionFixture.init(pixels);
        defer fixture.deinit();
        var scheduler: TestCompressionScheduler = .{};
        fixture.store.delivery.host_zlib = true;
        if (comptime @hasField(Store, "compression_scheduler")) {
            fixture.store.delivery.compression_scheduler = .{ .context = &scheduler, .start = TestCompressionScheduler.schedule };
        }
        const image = fixture.store.images.getPtr(identity(@enumFromInt(1), TransmissionFixture.metadata.key)).?;
        turn.* = 0;
        const started = Io.Clock.awake.now(std.testing.io).nanoseconds;
        while (true) {
            var budget: usize = compression_slice_per_frame;
            const before = Io.Clock.awake.now(std.testing.io).nanoseconds;
            const done = delivery.advanceCompression(&fixture.store, image, &budget);
            turn.* = @max(turn.*, @as(u64, @intCast(Io.Clock.awake.now(std.testing.io).nanoseconds - before)));
            if (comptime @hasField(Store, "compression_scheduler")) {
                scheduler.complete(&fixture.store);
            }
            if (done) {
                break;
            }
        }
        total.* = @intCast(Io.Clock.awake.now(std.testing.io).nanoseconds - started);
        const inflated = try inflateExact(std.testing.allocator, image.delivery.compressed.?, pixels.len);
        defer std.testing.allocator.free(inflated);
        try std.testing.expectEqualSlices(u8, pixels, inflated);
    }
    for ([_][]u64{ &turns, &totals }, [_][]const u8{ "compression_max_turn", "compression_total" }) |values, name| {
        std.mem.sort(u64, values, {}, std.sort.asc(u64));
        std.debug.print("PERF {s} n=20 p50_ns={d} p95_ns={d} p99_ns={d}\n", .{ name, values[10], values[18], values[19] });
    }
}

const TestCompressionScheduler = struct {
    pending: ?*Compression = null,

    fn schedule(context: *anyopaque, job: *Compression) anyerror!void {
        const scheduler: *TestCompressionScheduler = @ptrCast(@alignCast(context));
        try std.testing.expect(scheduler.pending == null);
        scheduler.pending = job;
    }

    fn complete(scheduler: *TestCompressionScheduler, store: *Store) void {
        const job = scheduler.pending orelse return;
        delivery.completeCompression(store, Compression.run(job));
        scheduler.pending = null;
    }
};

test "async compression owns its input and emits the same pixels" {
    const pixels = try std.testing.allocator.alloc(u8, TransmissionFixture.metadata.byte_len);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 0x30);
    var fixture = try TransmissionFixture.init(pixels);
    defer fixture.deinit();
    var scheduler: TestCompressionScheduler = .{};
    fixture.store.delivery.host_zlib = true;
    fixture.store.delivery.compression_scheduler = .{ .context = &scheduler, .start = TestCompressionScheduler.schedule };
    var graphics_writer = fixture.writer(transmission_budget_per_frame);
    var collected: Io.Writer.Allocating = .init(std.testing.allocator);
    defer collected.deinit();
    const buffer = try std.testing.allocator.alloc(u8, transmission_budget_per_frame * 2);
    defer std.testing.allocator.free(buffer);
    var turns: usize = 0;
    while (fixture.store.damage) {
        turns += 1;
        try std.testing.expect(turns < 32);
        var writer = Io.Writer.fixed(buffer);
        _ = try graphics_writer.write(&writer);
        try collected.writer.writeAll(writer.buffered());
        if (scheduler.pending) |job| {
            if (turns == 1) {
                try std.testing.expectEqual(@as(usize, 2), job.allocating.written().len);
            }
            const image = fixture.store.images.getPtr(identity(@enumFromInt(1), TransmissionFixture.metadata.key)).?;
            try std.testing.expect(job.input.ptr != image.pixels.ptr);
            try std.testing.expect(job.input_len <= compression_slice_per_frame);
            scheduler.complete(&fixture.store);
        }
    }
    const compressed = try decodeTransmissionPayloads(std.testing.allocator, collected.written());
    defer std.testing.allocator.free(compressed);
    const inflated = try inflateExact(std.testing.allocator, compressed, pixels.len);
    defer std.testing.allocator.free(inflated);
    try std.testing.expectEqualSlices(u8, pixels, inflated);
    try std.testing.expectEqual(@as(u64, 1), graphics_writer.stats.compressed_images);
}

test "an image deleted during compression releases its orphan only after completion" {
    const pixels = try std.testing.allocator.alloc(u8, TransmissionFixture.metadata.byte_len);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 0x30);
    var fixture = try TransmissionFixture.init(pixels);
    defer fixture.deinit();
    var scheduler: TestCompressionScheduler = .{};
    fixture.store.delivery.host_zlib = true;
    fixture.store.delivery.compression_scheduler = .{ .context = &scheduler, .start = TestCompressionScheduler.schedule };
    const image_key = identity(@enumFromInt(1), TransmissionFixture.metadata.key);
    const image = fixture.store.images.getPtr(image_key).?;
    var budget: usize = compression_slice_per_frame;
    try std.testing.expect(!delivery.advanceCompression(&fixture.store, image, &budget));
    try std.testing.expect(scheduler.pending != null);
    fixture.store.removeImageData(image_key);
    try std.testing.expect(fixture.store.delivery.orphan_compression);
    scheduler.complete(&fixture.store);
    try std.testing.expect(fixture.store.delivery.pending_compression == null);
    try std.testing.expect(!fixture.store.delivery.orphan_compression);
}

test "a zlib host ships a deflated stream that inflates to the pixels" {
    const pixels = try std.testing.allocator.alloc(u8, TransmissionFixture.metadata.byte_len);
    defer std.testing.allocator.free(pixels);
    // Browser-frame shape: flat fills with a sparse noise band.
    var prng = std.Random.DefaultPrng.init(9);
    for (pixels, 0..) |*byte, index| {
        byte.* = if (index % 16 == 3) prng.random().int(u8) else 0x30;
    }
    var fixture = try TransmissionFixture.init(pixels);
    defer fixture.deinit();
    fixture.store.delivery.host_zlib = true;

    var graphics_writer = fixture.writer(transmission_budget_per_frame);
    const frame_buffer = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(frame_buffer);
    var collected: Io.Writer.Allocating = .init(std.testing.allocator);
    defer collected.deinit();

    var frames: usize = 0;
    var total_written: usize = 0;
    while (true) {
        frames += 1;
        try std.testing.expect(frames < 16);
        var writer = Io.Writer.fixed(frame_buffer);
        total_written += try graphics_writer.write(&writer);
        try collected.writer.writeAll(writer.buffered());
        if (!fixture.store.damage) {
            break;
        }
    }

    // The header advertises the compression the payload actually carries.
    try std.testing.expect(std.mem.indexOf(u8, collected.written(), "o=z") != null);
    try std.testing.expect(total_written < pixels.len / 4);
    const payload = try decodeTransmissionPayloads(std.testing.allocator, collected.written());
    defer std.testing.allocator.free(payload);
    const inflated = try inflateExact(std.testing.allocator, payload, pixels.len);
    defer std.testing.allocator.free(inflated);
    try std.testing.expectEqualSlices(u8, pixels, inflated);
    // The transient zlib copy is gone once the transmission closed.
    const entry = fixture.store.images.getPtr(.{
        .pane_id = @enumFromInt(1),
        .image_id = 1,
        .generation = 1,
    }).?;
    try std.testing.expect(entry.delivery.compressed == null and entry.delivery.compression == null);
    try std.testing.expectEqual(@as(u64, 1), graphics_writer.stats.inline_images);
    try std.testing.expectEqual(@as(u64, 1), graphics_writer.stats.compressed_images);
    try std.testing.expect(graphics_writer.stats.compress_passes >= 1);
}

test "incompressible pixels fall back to a raw transmission" {
    const pixels = try std.testing.allocator.alloc(u8, TransmissionFixture.metadata.byte_len);
    defer std.testing.allocator.free(pixels);
    var prng = std.Random.DefaultPrng.init(11);
    prng.random().bytes(pixels);
    var fixture = try TransmissionFixture.init(pixels);
    defer fixture.deinit();
    fixture.store.delivery.host_zlib = true;

    var graphics_writer = fixture.writer(transmission_budget_per_frame * 8);
    const frame_buffer = try std.testing.allocator.alloc(u8, 4 * 1024 * 1024);
    defer std.testing.allocator.free(frame_buffer);
    var collected: Io.Writer.Allocating = .init(std.testing.allocator);
    defer collected.deinit();
    var frames: usize = 0;
    while (true) {
        frames += 1;
        try std.testing.expect(frames < 16);
        var writer = Io.Writer.fixed(frame_buffer);
        _ = try graphics_writer.write(&writer);
        try collected.writer.writeAll(writer.buffered());
        if (!fixture.store.damage) {
            break;
        }
    }

    try std.testing.expect(std.mem.indexOf(u8, collected.written(), "o=z") == null);
    const payload = try decodeTransmissionPayloads(std.testing.allocator, collected.written());
    defer std.testing.allocator.free(payload);
    try std.testing.expectEqualSlices(u8, pixels, payload);
}

test "a compressed transmission resumes across frames" {
    const pixels = try std.testing.allocator.alloc(u8, TransmissionFixture.metadata.byte_len);
    defer std.testing.allocator.free(pixels);
    // Compressible enough to keep the zlib stream, large enough that its
    // encoding still spans several baseline budgets.
    var prng = std.Random.DefaultPrng.init(13);
    for (0..pixels.len / 4) |pixel| {
        const noise = prng.random().int(u8);
        pixels[pixel * 4 + 0] = if (pixel % 3 == 0) noise else 0x20;
        pixels[pixel * 4 + 1] = if (pixel % 3 == 1) noise else 0x20;
        pixels[pixel * 4 + 2] = 0x20;
        pixels[pixel * 4 + 3] = 0xff;
    }
    var fixture = try TransmissionFixture.init(pixels);
    defer fixture.deinit();
    fixture.store.delivery.host_zlib = true;

    var graphics_writer = fixture.writer(64 * 1024);
    const frame_buffer = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(frame_buffer);
    var collected: Io.Writer.Allocating = .init(std.testing.allocator);
    defer collected.deinit();
    var frames: usize = 0;
    var resumed = false;
    while (true) {
        frames += 1;
        try std.testing.expect(frames < 64);
        var writer = Io.Writer.fixed(frame_buffer);
        _ = try graphics_writer.write(&writer);
        try collected.writer.writeAll(writer.buffered());
        if (fixture.store.delivery.partial != null) {
            try std.testing.expect(fixture.store.delivery.partial.?.compressed);
            resumed = true;
        }
        if (!fixture.store.damage) {
            break;
        }
    }

    try std.testing.expect(resumed);
    const payload = try decodeTransmissionPayloads(std.testing.allocator, collected.written());
    defer std.testing.allocator.free(payload);
    const inflated = try inflateExact(std.testing.allocator, payload, pixels.len);
    defer std.testing.allocator.free(inflated);
    try std.testing.expectEqualSlices(u8, pixels, inflated);
}

test "continuous replacements complete and hand off without a blank frame" {
    const pane_id: schema.PaneId = @enumFromInt(1);
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addRoot(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 10, .rows = 5 } });

    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const first: graphics.Image = .{
        .key = .{ .image_id = 7, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = first });
    try store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 1,
        .key = first.key,
        .offset = 0,
        .bytes = &.{ 1, 2, 3, 255 },
    });
    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 1,
        .placement = .{
            .key = first.key,
            .virtual_id = 1,
            .placement_id = 1,
            .x = 0,
            .y = 0,
        },
    });

    const layout_snapshot = model.layoutSnapshot(.{ .w = 10, .h = 5 });
    var graphics_writer: KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = layout_snapshot,
        .cell_width = 10,
        .cell_height = 20,
    };
    var small_buffer: [1024]u8 = undefined;
    var first_writer = Io.Writer.fixed(&small_buffer);
    _ = try graphics_writer.write(&first_writer);

    const placement_key: PlacementIdentity = .{ .pane_id = pane_id, .virtual_id = 1 };
    const placement_id = store.placements.get(placement_key).?.delivery.external_id;
    const first_id = store.images.get(identity(pane_id, first.key)).?.delivery.external_id;
    try std.testing.expectEqual(
        first_id,
        store.placements.get(placement_key).?.delivery.emitted_image_id.?,
    );

    const pixels = try std.testing.allocator.alloc(u8, 256 * 256 * 4);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 0x5a);
    const second: graphics.Image = .{
        .key = .{ .image_id = 7, .generation = 2 },
        .format = .rgba,
        .width = 256,
        .height = 256,
        .byte_len = pixels.len,
    };
    try store.applyImage(.{ .pane_id = pane_id, .revision = 2, .image = second });
    try store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 2,
        .key = second.key,
        .offset = 0,
        .bytes = pixels,
    });
    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 2,
        .placement = .{
            .key = second.key,
            .virtual_id = 1,
            .placement_id = 1,
            .x = 0,
            .y = 0,
        },
    });

    var frame_buffer: [transmission_budget_per_frame + 16 * 1024]u8 = undefined;
    var begin_second = Io.Writer.fixed(&frame_buffer);
    _ = try graphics_writer.write(&begin_second);
    try std.testing.expect(store.delivery.partial != null);
    try std.testing.expectEqual(
        first_id,
        store.placements.get(placement_key).?.delivery.emitted_image_id.?,
    );

    // A third browser frame arrives before the second has crossed the host
    // terminal. It replaces pending work, but cannot abort the open KGP stream.
    const third: graphics.Image = .{
        .key = .{ .image_id = 7, .generation = 3 },
        .format = .rgba,
        .width = 256,
        .height = 256,
        .byte_len = pixels.len,
    };
    try store.applyImage(.{ .pane_id = pane_id, .revision = 3, .image = third });
    try store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 3,
        .key = third.key,
        .offset = 0,
        .bytes = pixels,
    });
    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 3,
        .placement = .{
            .key = third.key,
            .virtual_id = 1,
            .placement_id = 1,
            .x = 0,
            .y = 0,
        },
    });
    try store.deleteImage(.{
        .pane_id = pane_id,
        .revision = 3,
        .key = second.key,
    });
    try std.testing.expectEqual(@as(usize, 3), store.images.count());

    const second_id = store.images.get(identity(pane_id, second.key)).?.delivery.external_id;
    const third_id = store.images.get(identity(pane_id, third.key)).?.delivery.external_id;
    var second_placement_buffer: [64]u8 = undefined;
    const second_placement = try std.fmt.bufPrint(
        &second_placement_buffer,
        "\x1b_Ga=p,i={d},p={d},",
        .{ second_id, placement_id },
    );
    var third_placement_buffer: [64]u8 = undefined;
    const third_placement = try std.fmt.bufPrint(
        &third_placement_buffer,
        "\x1b_Ga=p,i={d},p={d},",
        .{ third_id, placement_id },
    );
    var delete_first_buffer: [64]u8 = undefined;
    const delete_first = try std.fmt.bufPrint(
        &delete_first_buffer,
        "\x1b_Ga=d,d=i,i={d},p={d},q=2\x1b\\",
        .{ first_id, placement_id },
    );
    var delete_second_buffer: [64]u8 = undefined;
    const delete_second = try std.fmt.bufPrint(
        &delete_second_buffer,
        "\x1b_Ga=d,d=i,i={d},p={d},q=2\x1b\\",
        .{ second_id, placement_id },
    );

    var frames: usize = 1;
    var second_handoff = false;
    var third_handoff = false;
    while (store.damage) {
        frames += 1;
        try std.testing.expect(frames < 16);
        var writer = Io.Writer.fixed(&frame_buffer);
        _ = try graphics_writer.write(&writer);
        const output = writer.buffered();
        try std.testing.expect(std.mem.indexOf(u8, output, "\x1b_Gm=0;\x1b\\") == null);
        if (std.mem.indexOf(u8, output, second_placement)) |placement_at| {
            const delete_at = std.mem.indexOf(u8, output, delete_first) orelse
                return error.MissingOldPlacementDelete;
            try std.testing.expect(placement_at < delete_at);
            second_handoff = true;
        }
        if (std.mem.indexOf(u8, output, third_placement)) |placement_at| {
            const delete_at = std.mem.indexOf(u8, output, delete_second) orelse
                return error.MissingOldPlacementDelete;
            try std.testing.expect(placement_at < delete_at);
            third_handoff = true;
        }
        if (!second_handoff) {
            try std.testing.expectEqual(
                first_id,
                store.placements.get(placement_key).?.delivery.emitted_image_id.?,
            );
        }
        if (second_handoff and !third_handoff) {
            try std.testing.expectEqual(
                second_id,
                store.placements.get(placement_key).?.delivery.emitted_image_id.?,
            );
        }
    }

    try std.testing.expect(second_handoff);
    try std.testing.expect(third_handoff);
    try std.testing.expectEqual(
        third_id,
        store.placements.get(placement_key).?.delivery.emitted_image_id.?,
    );
    try std.testing.expectEqual(@as(usize, 1), store.images.count());
    try std.testing.expect(store.images.contains(identity(pane_id, third.key)));
}

test "image and placement deletes encode exactly and clear client state" {
    var output: [256]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    _ = try writeDeleteImage(&writer, 7);
    _ = try writeDeletePlacement(&writer, 7, 11);
    _ = try writeDeleteImageRange(&writer, 1, 9);
    try std.testing.expectEqualStrings(
        "\x1b_Ga=d,d=I,i=7,q=2\x1b\\" ++
            "\x1b_Ga=d,d=i,i=7,p=11,q=2\x1b\\" ++
            "\x1b_Ga=d,d=R,x=1,y=9,q=2\x1b\\",
        writer.buffered(),
    );

    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    const metadata: graphics.Image = .{
        .key = .{ .image_id = 7, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = metadata });
    try store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 1,
        .key = metadata.key,
        .offset = 0,
        .bytes = &.{ 1, 2, 3, 4 },
    });
    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 1,
        .placement = .{
            .key = metadata.key,
            .virtual_id = 11,
            .placement_id = 11,
            .x = 0,
            .y = 0,
        },
    });
    try store.deletePlacement(.{
        .pane_id = pane_id,
        .revision = 2,
        .key = metadata.key,
        .virtual_id = 11,
        .placement_id = 11,
    });
    try std.testing.expectEqual(@as(usize, 0), store.placements.count());
    try store.deleteImage(.{ .pane_id = pane_id, .revision = 3, .key = metadata.key });
    try std.testing.expectEqual(@as(usize, 0), store.images.count());
    try std.testing.expectEqual(@as(usize, 0), store.total_bytes);
}

test "client graphics store enforces image and chunk counts" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    for (0..graphics.max_images_per_pane) |index| {
        const image_id: u32 = @intCast(index + 1);
        try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = .{
            .key = .{ .image_id = image_id, .generation = 1 },
            .format = .rgba,
            .width = 1,
            .height = 1,
            .byte_len = 4,
        } });
    }
    try std.testing.expectError(error.GraphicsImageLimitExceeded, store.applyImage(.{
        .pane_id = pane_id,
        .revision = 1,
        .image = .{
            .key = .{ .image_id = 1000, .generation = 1 },
            .format = .rgba,
            .width = 1,
            .height = 1,
            .byte_len = 4,
        },
    }));

    const entry = store.images.getPtr(.{
        .pane_id = pane_id,
        .image_id = 1,
        .generation = 1,
    }).?;
    entry.chunks = graphics.max_chunks_per_image;
    try std.testing.expectError(error.GraphicsChunkLimitExceeded, store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 1,
        .key = .{ .image_id = 1, .generation = 1 },
        .offset = 0,
        .bytes = &.{1},
    }));

    try store.applyImage(.{ .pane_id = pane_id, .revision = 2, .image = .{
        .key = .{ .image_id = 1, .generation = 2 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    } });
    try store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 2,
        .key = .{ .image_id = 1, .generation = 2 },
        .offset = 0,
        .bytes = &.{ 1, 2, 3, 4 },
    });
    try std.testing.expectEqual(graphics.max_images_per_pane, store.images.count());
    try std.testing.expect(store.images.contains(.{
        .pane_id = pane_id,
        .image_id = 1,
        .generation = 2,
    }));
}

test "a completed newer generation replaces incomplete client image storage" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = .{
        .key = .{ .image_id = 7, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    } });
    try store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 1,
        .key = .{ .image_id = 7, .generation = 1 },
        .offset = 0,
        .bytes = &.{1},
    });
    try store.applyImage(.{ .pane_id = pane_id, .revision = 2, .image = .{
        .key = .{ .image_id = 7, .generation = 2 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    } });
    try store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 2,
        .key = .{ .image_id = 7, .generation = 2 },
        .offset = 0,
        .bytes = &.{ 5, 6, 7, 8 },
    });
    try std.testing.expectEqual(@as(usize, 1), store.images.count());
    try std.testing.expectEqual(@as(usize, 4), store.total_bytes);
    try std.testing.expect(store.images.contains(.{
        .pane_id = pane_id,
        .image_id = 7,
        .generation = 2,
    }));
}

test "a flood of stale generations of one image cannot overflow eviction" {
    // Regression: `removeOtherGenerations` collected obsolete keys into a
    // fixed `[max_images_per_pane]` stack array, but retransmissions of one
    // image id bypass the logical-count limit, so far more than that many
    // generations could coexist and completing one wrote past the array.
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    const generations = graphics.max_images_per_pane + 8;
    var generation: u64 = 1;
    while (generation <= generations) : (generation += 1) {
        try store.applyImage(.{ .pane_id = pane_id, .revision = generation, .image = .{
            .key = .{ .image_id = 7, .generation = generation },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        } });
    }
    try store.applyChunk(.{
        .pane_id = pane_id,
        .revision = generations,
        .key = .{ .image_id = 7, .generation = generations },
        .offset = 0,
        .bytes = &.{ 1, 2, 3 },
    });
    try std.testing.expectEqual(@as(usize, 1), store.images.count());
    try std.testing.expect(store.images.contains(.{
        .pane_id = pane_id,
        .image_id = 7,
        .generation = generations,
    }));
    try std.testing.expectEqual(@as(usize, 3), store.total_bytes);
}

test "the store tracks panes for a whole client, not one tab" {
    // Regression: `revisions` and `hidden_panes` were fixed arrays sized
    // `schema.max_panes_per_tab`, but one store serves every tab of the
    // client, so the 65th pane with graphics - or the 65th hidden pane -
    // returned ClientPaneLimitExceeded and the error killed the client.
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const panes = schema.max_panes_per_tab + 8;
    var index: usize = 0;
    while (index < panes) : (index += 1) {
        const pane_id: schema.PaneId = @enumFromInt(index + 1);
        try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        } });
        try store.setPaneVisible(pane_id, false);
        try std.testing.expect(!store.paneVisible(pane_id));
    }
    try std.testing.expectEqual(@as(usize, panes), store.images.count());
}

test "pane usage counters match a full recount" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const first_pane: schema.PaneId = @enumFromInt(1);
    const second_pane: schema.PaneId = @enumFromInt(2);
    const metadata: graphics.Image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    for ([_]schema.PaneId{ first_pane, second_pane }) |pane_id| {
        try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = metadata });
        try store.applyChunk(.{
            .pane_id = pane_id,
            .revision = 1,
            .key = metadata.key,
            .offset = 0,
            .bytes = &.{ 1, 2, 3, 4 },
        });
        try store.applyPlacement(.{ .pane_id = pane_id, .revision = 1, .placement = .{
            .key = metadata.key,
            .virtual_id = 1,
            .placement_id = 1,
            .x = 0,
            .y = 0,
        } });
    }
    try store.deletePlacement(.{
        .pane_id = second_pane,
        .revision = 2,
        .key = metadata.key,
        .virtual_id = 1,
        .placement_id = 1,
    });
    try store.deleteImage(.{ .pane_id = second_pane, .revision = 3, .key = metadata.key });

    for ([_]schema.PaneId{ first_pane, second_pane }) |pane_id| {
        var counted: Store.PaneUsage = .{};
        var images = store.images.iterator();
        while (images.next()) |entry| {
            if (entry.key_ptr.pane_id != pane_id) {
                continue;
            }
            counted.count += 1;
            counted.bytes += entry.value_ptr.pixels.len;
        }
        var placements = store.placements.iterator();
        while (placements.next()) |entry| {
            if (entry.key_ptr.pane_id == pane_id) {
                counted.placements += 1;
            }
        }
        const tracked: Store.PaneUsage = store.usage.get(pane_id) orelse .{};
        try std.testing.expectEqual(counted.count, tracked.count);
        try std.testing.expectEqual(counted.bytes, tracked.bytes);
        try std.testing.expectEqual(counted.placements, tracked.placements);
        try std.testing.expectEqual(counted.count != 0, store.hasPaneGraphics(pane_id));
    }
    const credit = store.peekCredit().?;
    try std.testing.expectEqual(second_pane, credit.pane_id);
    try std.testing.expectEqual(@as(usize, 4), credit.bytes);
    store.consumeCredit(credit);
    // A pane with nothing left and no unreturned credit holds no usage entry.
    try std.testing.expect(!store.usage.contains(second_pane));
}

test "snapshot replacement returns client image credit" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    const image: graphics.Image = .{
        .key = .{ .image_id = 7, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = image });
    try store.applySnapshot(.{ .pane_id = pane_id, .revision = 2, .phase = .begin });

    const credit = store.peekCredit().?;
    try std.testing.expectEqual(pane_id, credit.pane_id);
    try std.testing.expectEqual(@as(usize, 4), credit.bytes);
    store.consumeCredit(credit);
    try std.testing.expect(store.peekCredit() == null);

    // Detaching destroys client state; there is no runtime attachment left
    // to receive credit for those bytes.
    try store.applyImage(.{ .pane_id = pane_id, .revision = 2, .image = image });
    store.clearPane(pane_id);
    try std.testing.expect(store.peekCredit() == null);
}

test "shared client pixels have a bounded POSIX lifetime" {
    if (comptime !supportsSharedMemory()) {
        return error.SkipZigTest;
    }

    var store = Store.initSharedMemory(std.testing.allocator);
    defer store.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    const image: graphics.Image = .{
        .key = .{ .image_id = 7, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = image });
    const shared = store.images.get(identity(pane_id, image.key)).?.shared.?;
    const fd = std.c.shm_open(
        shared.sliceZ(),
        @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })),
        @as(u16, 0),
    );
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(fd));
    _ = std.c.close(fd);

    try store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 1,
        .key = image.key,
        .offset = 0,
        .bytes = &.{ 1, 2, 3, 255 },
    });
    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 1,
        .placement = .{
            .key = image.key,
            .virtual_id = 1,
            .placement_id = 1,
            .x = 0,
            .y = 0,
        },
    });
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addRoot(.{ .pane_id = pane_id, .location = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 10, .rows = 5 } });
    var graphics_writer: KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = model.layoutSnapshot(.{ .w = 10, .h = 5 }),
        .cell_width = 10,
        .cell_height = 20,
    };
    var output: [1024]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    _ = try graphics_writer.write(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "t=s") != null);
    try std.testing.expect(store.delivery.partial == null);

    try store.deletePlacement(.{
        .pane_id = pane_id,
        .revision = 2,
        .key = image.key,
        .virtual_id = 1,
        .placement_id = 1,
    });
    try store.deleteImage(.{ .pane_id = pane_id, .revision = 3, .key = image.key });
    try std.testing.expectEqual(@as(usize, 1), store.images.count());
    try std.testing.expect(store.peekCredit() == null);
    var waiting_output: [1024]u8 = undefined;
    var waiting_writer = Io.Writer.fixed(&waiting_output);
    _ = try graphics_writer.write(&waiting_writer);
    try std.testing.expect(store.damage);

    // Ghostty unlinks the object after copying it. Until then the client keeps
    // the mapping resident and cannot return its memory credit to the runtime.
    try std.testing.expectEqual(@as(c_int, 0), std.c.shm_unlink(shared.sliceZ()));
    var released_output: [1024]u8 = undefined;
    var released_writer = Io.Writer.fixed(&released_output);
    _ = try graphics_writer.write(&released_writer);
    try std.testing.expectEqual(@as(usize, 0), store.images.count());
    const credit = store.peekCredit().?;
    try std.testing.expectEqual(@as(usize, 4), credit.bytes);
    store.consumeCredit(credit);
    const missing = std.c.shm_open(
        shared.sliceZ(),
        @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })),
        @as(u16, 0),
    );
    try std.testing.expectEqual(std.posix.E.NOENT, std.posix.errno(missing));
}

test "shared transmission sends only a KGP resource name" {
    var output: [256]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    const written = try writeSharedTransmission(&writer, .{
        .external_id = 7,
        .image = .{
            .key = .{ .image_id = 7, .generation = 1 },
            .format = .rgba,
            .width = 1,
            .height = 1,
            .byte_len = 4,
        },
        .name = "/telar-test",
    });
    try std.testing.expectEqualStrings(
        "\x1b_Ga=t,f=32,s=1,v=1,t=s,i=7,q=0;L3RlbGFyLXRlc3Q=\x1b\\",
        writer.buffered(),
    );
    try std.testing.expectEqual(writer.buffered().len, written);
}

test "a host acknowledgement retires a replaced shared image without probing" {
    if (comptime !supportsSharedMemory()) {
        return error.SkipZigTest;
    }

    var store = Store.initSharedMemory(std.testing.allocator);
    defer store.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    const source = [_]u8{ 1, 2, 3, 255 };
    var first_name_buffer: [64]u8 = undefined;
    const first_name = try graphics.ShmName.init(try std.fmt.bufPrint(&first_name_buffer, "/tlrtest-ack1-{d}", .{std.c.getpid()}));
    _ = std.c.shm_unlink(first_name.sliceZ());
    try testCreateSharedObject(first_name.sliceZ(), &source);
    defer _ = std.c.shm_unlink(first_name.sliceZ());
    var second_name_buffer: [64]u8 = undefined;
    const second_name = try graphics.ShmName.init(try std.fmt.bufPrint(&second_name_buffer, "/tlrtest-ack2-{d}", .{std.c.getpid()}));
    _ = std.c.shm_unlink(second_name.sliceZ());
    try testCreateSharedObject(second_name.sliceZ(), &source);
    defer _ = std.c.shm_unlink(second_name.sliceZ());

    const first: graphics.Image = .{ .key = .{ .image_id = 7, .generation = 1 }, .format = .rgba, .width = 1, .height = 1, .byte_len = 4 };
    try store.applySharedImage(.{ .pane_id = pane_id, .revision = 1, .image = first, .name = first_name });
    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 1,
        .placement = .{ .key = first.key, .virtual_id = 1, .placement_id = 1, .x = 0, .y = 0 },
    });
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addRoot(.{ .pane_id = pane_id, .location = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 10, .rows = 5 } });
    var graphics_writer: KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = model.layoutSnapshot(.{ .w = 10, .h = 5 }),
        .cell_width = 10,
        .cell_height = 20,
    };
    var output: [1024]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    _ = try graphics_writer.write(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "q=0;") != null);
    const first_external = store.images.get(identity(pane_id, first.key)).?.delivery.external_id;

    // A reply for an id the store does not hold changes nothing.
    try std.testing.expect(!delivery.noteHostReply(&store, first_external + 1000, true));
    try std.testing.expect(delivery.noteHostReply(&store, first_external, true));
    try std.testing.expect(store.images.get(identity(pane_id, first.key)).?.delivery.host_acked);

    // The object still exists: without the reply a probe would keep the
    // replaced generation alive. With it, the replacement retires it.
    const second: graphics.Image = .{ .key = .{ .image_id = 7, .generation = 2 }, .format = .rgba, .width = 1, .height = 1, .byte_len = 4 };
    try store.applySharedImage(.{ .pane_id = pane_id, .revision = 2, .image = second, .name = second_name });
    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 2,
        .placement = .{ .key = second.key, .virtual_id = 1, .placement_id = 1, .x = 0, .y = 0 },
    });
    var second_output: [1024]u8 = undefined;
    var second_writer = Io.Writer.fixed(&second_output);
    _ = try graphics_writer.write(&second_writer);
    try std.testing.expectEqual(@as(usize, 1), store.images.count());
    try std.testing.expect(store.images.get(identity(pane_id, second.key)) != null);
    const credit = store.peekCredit() orelse return error.CreditNotReleased;
    try std.testing.expectEqual(@as(usize, 4), credit.bytes);
    store.consumeCredit(credit);
}

test "a host error reply reclaims the shared name and retransmits inline" {
    if (comptime !supportsSharedMemory()) {
        return error.SkipZigTest;
    }

    var store = Store.initSharedMemory(std.testing.allocator);
    defer store.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    const source = [_]u8{ 1, 2, 3, 255 };
    var name_buffer: [64]u8 = undefined;
    const name = try graphics.ShmName.init(try std.fmt.bufPrint(&name_buffer, "/tlrtest-nack-{d}", .{std.c.getpid()}));
    _ = std.c.shm_unlink(name.sliceZ());
    try testCreateSharedObject(name.sliceZ(), &source);
    defer _ = std.c.shm_unlink(name.sliceZ());
    const image: graphics.Image = .{ .key = .{ .image_id = 7, .generation = 1 }, .format = .rgba, .width = 1, .height = 1, .byte_len = 4 };
    try store.applySharedImage(.{ .pane_id = pane_id, .revision = 1, .image = image, .name = name });
    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 1,
        .placement = .{ .key = image.key, .virtual_id = 1, .placement_id = 1, .x = 0, .y = 0 },
    });
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addRoot(.{ .pane_id = pane_id, .location = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 10, .rows = 5 } });
    var graphics_writer: KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = model.layoutSnapshot(.{ .w = 10, .h = 5 }),
        .cell_width = 10,
        .cell_height = 20,
    };
    var output: [1024]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    _ = try graphics_writer.write(&writer);
    const external = store.images.get(identity(pane_id, image.key)).?.delivery.external_id;

    try std.testing.expect(delivery.noteHostReply(&store, external, false));

    try std.testing.expect(store.damage);
    var retry: [4096]u8 = undefined;
    var retry_writer = Io.Writer.fixed(&retry);
    _ = try graphics_writer.write(&retry_writer);
    try std.testing.expect(std.mem.indexOf(u8, retry_writer.buffered(), "t=d") != null);
    try std.testing.expect(std.mem.indexOf(u8, retry_writer.buffered(), "t=s") == null);
    try std.testing.expectEqual(@as(u64, 1), graphics_writer.stats.inline_images);
}

test "graphics revisions ignore stale deltas and validate snapshots" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    const metadata: graphics.Image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    try store.applyImage(.{ .pane_id = pane_id, .revision = 5, .image = metadata });
    try std.testing.expectEqual(@as(u64, 1), store.ingressVersion());
    try store.deleteImage(.{ .pane_id = pane_id, .revision = 4, .key = metadata.key });
    try std.testing.expect(store.images.contains(identity(pane_id, metadata.key)));
    try std.testing.expectEqual(@as(u64, 1), store.ingressVersion());

    try store.applySnapshot(.{ .pane_id = pane_id, .revision = 8, .phase = .begin });
    try std.testing.expectEqual(@as(u64, 2), store.ingressVersion());
    try std.testing.expectError(error.GraphicsResyncRequired, store.applyImage(.{
        .pane_id = pane_id,
        .revision = 9,
        .image = metadata,
    }));
    try std.testing.expectEqual(@as(u64, 2), store.ingressVersion());
    try store.applySnapshot(.{ .pane_id = pane_id, .revision = 10, .phase = .begin });
    try store.applySnapshot(.{ .pane_id = pane_id, .revision = 10, .phase = .end });
    try std.testing.expectEqual(@as(u64, 4), store.ingressVersion());
}

fn testCreateSharedObject(name: [:0]const u8, pixels: []const u8) !void {
    const fd = std.c.shm_open(
        name,
        @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true })),
        @as(u16, 0o600),
    );
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(fd));
    defer _ = std.c.close(fd);
    try std.testing.expectEqual(@as(c_int, 0), std.c.ftruncate(fd, @intCast(pixels.len)));
    const map = try std.posix.mmap(
        null,
        pixels.len,
        .{ .READ = true, .WRITE = true },
        std.c.MAP{ .TYPE = .SHARED },
        fd,
        0,
    );
    defer std.posix.munmap(map);
    @memcpy(map[0..pixels.len], pixels);
}

test "an undersized runtime shared object is rejected and unlinked" {
    if (comptime !supportsSharedMemory()) {
        return error.SkipZigTest;
    }

    var store = Store.initSharedMemory(std.testing.allocator);
    defer store.deinit();
    var name_buffer: [64]u8 = undefined;
    const name = try graphics.ShmName.init(try std.fmt.bufPrint(&name_buffer, "/tlrtest-short-{d}", .{std.c.getpid()}));
    _ = std.c.shm_unlink(name.sliceZ());
    defer _ = std.c.shm_unlink(name.sliceZ());
    try testCreateSharedObject(name.sliceZ(), "RGBA");
    // Exceed Darwin's page-rounded shared object size as well as Linux's size.
    const height = std.heap.pageSize() / 512 + 1;

    try std.testing.expectError(error.GraphicsSharedMappingFailed, store.applySharedImage(.{
        .pane_id = @enumFromInt(1),
        .revision = 1,
        .image = .{
            .key = .{ .image_id = 7, .generation = 1 },
            .format = .rgba,
            .width = 128,
            .height = @intCast(height),
            .byte_len = 512 * height,
        },
        .name = name,
    }));
    try std.testing.expectEqual(@as(usize, 0), store.images.count());
    try std.testing.expectEqual(@as(c_int, -1), std.c.shm_unlink(name.sliceZ()));
    try std.testing.expectEqual(std.posix.E.NOENT, std.posix.errno(-1));
}

test "a runtime-named image maps without copying and hands the host its name" {
    if (comptime !supportsSharedMemory()) {
        return error.SkipZigTest;
    }

    var store = Store.initSharedMemory(std.testing.allocator);
    defer store.deinit();
    var name_buffer: [64]u8 = undefined;
    const name = try graphics.ShmName.init(try std.fmt.bufPrint(
        &name_buffer,
        "/tlrtest-map-{d}",
        .{std.c.getpid()},
    ));
    _ = std.c.shm_unlink(name.sliceZ());
    const source = [_]u8{ 1, 2, 3, 255 };
    try testCreateSharedObject(name.sliceZ(), &source);

    const pane_id: schema.PaneId = @enumFromInt(1);
    const image: graphics.Image = .{
        .key = .{ .image_id = 7, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    try store.applySharedImage(.{
        .pane_id = pane_id,
        .revision = 1,
        .image = image,
        .name = name,
    });
    const entry = store.images.get(identity(pane_id, image.key)).?;
    try std.testing.expectEqual(@as(usize, 4), entry.received);
    try std.testing.expectEqualSlices(u8, &source, entry.pixels);

    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 1,
        .placement = .{
            .key = image.key,
            .virtual_id = 1,
            .placement_id = 1,
            .x = 0,
            .y = 0,
        },
    });
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addRoot(.{ .pane_id = pane_id, .location = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 10, .rows = 5 } });
    var graphics_writer: KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = model.layoutSnapshot(.{ .w = 10, .h = 5 }),
        .cell_width = 10,
        .cell_height = 20,
    };
    var output: [1024]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    _ = try graphics_writer.write(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "t=s") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "t=d") == null);

    // Ghostty consumes and unlinks; retiring then releases the credit.
    try std.testing.expectEqual(@as(c_int, 0), std.c.shm_unlink(name.sliceZ()));
    try store.deletePlacement(.{
        .pane_id = pane_id,
        .revision = 2,
        .key = image.key,
        .virtual_id = 1,
        .placement_id = 1,
    });
    try store.deleteImage(.{ .pane_id = pane_id, .revision = 3, .key = image.key });
    var released_output: [1024]u8 = undefined;
    var released_writer = Io.Writer.fixed(&released_output);
    _ = try graphics_writer.write(&released_writer);
    try std.testing.expectEqual(@as(usize, 0), store.images.count());
    const credit = store.peekCredit().?;
    try std.testing.expectEqual(@as(usize, 4), credit.bytes);
    store.consumeCredit(credit);
}

test "a control pass hands the host shared names and placements without pixel streams" {
    if (comptime !supportsSharedMemory()) {
        return error.SkipZigTest;
    }

    var store = Store.initSharedMemory(std.testing.allocator);
    defer store.deinit();
    var name_buffer: [64]u8 = undefined;
    const name = try graphics.ShmName.init(try std.fmt.bufPrint(
        &name_buffer,
        "/tlrtest-control-{d}",
        .{std.c.getpid()},
    ));
    _ = std.c.shm_unlink(name.sliceZ());
    const source = [_]u8{ 1, 2, 3, 255 };
    try testCreateSharedObject(name.sliceZ(), &source);
    defer _ = std.c.shm_unlink(name.sliceZ());

    const pane_id: schema.PaneId = @enumFromInt(1);
    const shared_image: graphics.Image = .{
        .key = .{ .image_id = 7, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    try store.applySharedImage(.{ .pane_id = pane_id, .revision = 1, .image = shared_image, .name = name });
    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 1,
        .placement = .{ .key = shared_image.key, .virtual_id = 1, .placement_id = 1, .x = 0, .y = 0 },
    });
    const inline_image: graphics.Image = .{
        .key = .{ .image_id = 8, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = inline_image });
    try store.applyChunk(.{ .pane_id = pane_id, .revision = 1, .key = inline_image.key, .offset = 0, .bytes = &source });
    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 1,
        .placement = .{ .key = inline_image.key, .virtual_id = 2, .placement_id = 2, .x = 1, .y = 0 },
    });
    // A shared-memory client also names its own images; a host that lost
    // one is served inline, which is the bulk pass's job.
    store.images.getPtr(identity(pane_id, inline_image.key)).?.delivery.force_direct = true;
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addRoot(.{ .pane_id = pane_id, .location = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 10, .rows = 5 } });
    const layout_snapshot = model.layoutSnapshot(.{ .w = 10, .h = 5 });

    var control: KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = layout_snapshot,
        .cell_width = 10,
        .cell_height = 20,
        .mode = .control,
    };
    var control_output: [1024]u8 = undefined;
    var control_writer = Io.Writer.fixed(&control_output);
    _ = try control.write(&control_writer);
    const control_bytes = control_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, control_bytes, "t=s") != null);
    try std.testing.expect(std.mem.indexOf(u8, control_bytes, "a=p,") != null);
    try std.testing.expect(std.mem.indexOf(u8, control_bytes, "t=d") == null);
    try std.testing.expectEqual(@as(u64, 1), control.stats.shared_images);
    try std.testing.expectEqual(@as(u64, 0), control.stats.inline_images);
    // The inline image keeps its damage for the bulk pass.
    try std.testing.expect(store.damage);

    var bulk: KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = layout_snapshot,
        .cell_width = 10,
        .cell_height = 20,
    };
    var bulk_output: [1024]u8 = undefined;
    var bulk_writer = Io.Writer.fixed(&bulk_output);
    _ = try bulk.write(&bulk_writer);
    const bulk_bytes = bulk_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, bulk_bytes, "t=d") != null);
    try std.testing.expect(std.mem.indexOf(u8, bulk_bytes, "t=s") == null);
    try std.testing.expectEqual(@as(u64, 1), bulk.stats.inline_images);
    try std.testing.expect(!store.damage);
}

test "a control pass emits nothing while a chunked transfer is open" {
    const pane_id: schema.PaneId = @enumFromInt(1);
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addRoot(.{ .pane_id = pane_id, .location = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 10, .rows = 5 } });
    const layout_snapshot = model.layoutSnapshot(.{ .w = 10, .h = 5 });

    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const pixels = try std.testing.allocator.alloc(u8, 64 * 64 * 4);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 0x5a);
    const image: graphics.Image = .{
        .key = .{ .image_id = 7, .generation = 1 },
        .format = .rgba,
        .width = 64,
        .height = 64,
        .byte_len = pixels.len,
    };
    try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = image });
    try store.applyChunk(.{ .pane_id = pane_id, .revision = 1, .key = image.key, .offset = 0, .bytes = pixels });
    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 1,
        .placement = .{ .key = image.key, .virtual_id = 1, .placement_id = 1, .x = 0, .y = 0 },
    });

    var bulk: KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = layout_snapshot,
        .cell_width = 10,
        .cell_height = 20,
        .budget = 4096,
    };
    var bulk_output: [8192]u8 = undefined;
    var bulk_writer = Io.Writer.fixed(&bulk_output);
    _ = try bulk.write(&bulk_writer);
    try std.testing.expect(store.delivery.partial != null);

    var control: KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = layout_snapshot,
        .cell_width = 10,
        .cell_height = 20,
        .mode = .control,
    };
    var control_output: [1024]u8 = undefined;
    var control_writer = Io.Writer.fixed(&control_output);
    try std.testing.expectEqual(@as(usize, 0), try control.write(&control_writer));
    try std.testing.expect(store.delivery.partial != null);
    try std.testing.expect(store.damage);
}

test "a host that never consumes shared names loses them and gets pixels inline" {
    if (comptime !supportsSharedMemory()) {
        return error.SkipZigTest;
    }

    var store = Store.initSharedMemory(std.testing.allocator);
    defer store.deinit();
    const pane_id: schema.PaneId = @enumFromInt(1);
    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addRoot(.{ .pane_id = pane_id, .location = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 10, .rows = 5 } });
    var graphics_writer: KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = model.layoutSnapshot(.{ .w = 10, .h = 5 }),
        .cell_width = 10,
        .cell_height = 20,
    };

    const source = [_]u8{ 9, 9, 9, 255 };
    for ([_][]const u8{ "a1", "a2" }, 1..) |suffix, generation| {
        var name_buffer: [64]u8 = undefined;
        const name = try graphics.ShmName.init(try std.fmt.bufPrint(
            &name_buffer,
            "/tlrtest-exp-{s}-{d}",
            .{ suffix, std.c.getpid() },
        ));
        _ = std.c.shm_unlink(name.sliceZ());
        try testCreateSharedObject(name.sliceZ(), &source);
        try store.applySharedImage(.{
            .pane_id = pane_id,
            .revision = generation,
            .image = .{
                .key = .{ .image_id = 7, .generation = generation },
                .format = .rgba,
                .width = 1,
                .height = 1,
                .byte_len = 4,
            },
            .name = name,
        });
        var output: [4096]u8 = undefined;
        var writer = Io.Writer.fixed(&output);
        _ = try graphics_writer.write(&writer);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "t=s") != null);

        // The host never opens the object. Past the deadline the client
        // reclaims it and retransmits the pixels inline from the mapping.
        store.delivery.pass_counter +%= shared_consume_deadline_passes;
        var retry_output: [4096]u8 = undefined;
        var retry_writer = Io.Writer.fixed(&retry_output);
        _ = try graphics_writer.write(&retry_writer);
        try std.testing.expect(std.mem.indexOf(u8, retry_writer.buffered(), "t=d") != null);
        const missing = std.c.shm_open(
            name.sliceZ(),
            @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })),
            @as(u16, 0),
        );
        try std.testing.expectEqual(std.posix.E.NOENT, std.posix.errno(missing));
    }

    // Two expiries prove the host cannot consume names at all; the session
    // stops offering them.
    try std.testing.expect(!store.shared_memory);
}
