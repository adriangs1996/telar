const std = @import("std");
const modal = @import("modal.zig");
const Asset = @import("Asset.zig");
const ModalRenderKey = @import("ModalRenderKey.zig");
const RectType = @import("telar-core").Rect;
const ConfigurationType = @import("telar-client").SidebarRendererInput;
const PaletteType = @import("telar-client").Palette;
const writeTransmissionAbort_module = @import("kitty_protocol").writeTransmissionAbort;
const writeDeleteImage_module = @import("kitty_protocol").writeDeleteImage;
const kitty_codec = @import("kitty_codec.zig");
const writeDeletePlacement_module = @import("kitty_protocol").writeDeletePlacement;
const Renderer = @This();

gpa: std.mem.Allocator,
assets: [modal.asset_count]Asset = @splat(.{}),
supported: bool = false,
cell_width: u16 = 0,
cell_height: u16 = 0,
key: ?ModalRenderKey = null,
desired_area: ?RectType = null,
emitted_area: ?RectType = null,
frame_usable: bool = false,
partial: ?modal.AssetKind = null,
abort_pending: bool = false,

pub fn init(gpa: std.mem.Allocator) Renderer {
    return .{ .gpa = gpa };
}

pub fn deinit(renderer: *Renderer) void {
    for (&renderer.assets) |*asset| if (asset.pixels.len != 0)
        renderer.gpa.free(asset.pixels);
}

pub fn retainedBytes(renderer: *const Renderer) usize {
    var total: usize = 0;
    for (renderer.assets) |asset| total += asset.pixels.len;
    return total;
}

/// Applies host graphics support and cell geometry to modal rendering.
/// For example: `_ = renderer.configure(.{ .support = .supported, .cell_width = 10, .cell_height = 20 });`.
pub fn configure(renderer: *Renderer, configuration: ConfigurationType) bool {
    const supported = configuration.support == .supported;
    if (renderer.supported == supported and renderer.cell_width == configuration.cell_width and
        renderer.cell_height == configuration.cell_height)
    {
        return false;
    }
    renderer.cancelPartial();
    renderer.supported = supported;
    renderer.cell_width = configuration.cell_width;
    renderer.cell_height = configuration.cell_height;
    renderer.key = null;
    if (!supported) {
        renderer.frame_usable = false;
        renderer.desired_area = null;
    }
    return true;
}

pub fn prepare(renderer: *Renderer, area: RectType, palette: *const PaletteType) void {
    renderer.frame_usable = renderer.supported and renderer.cell_width != 0 and
        renderer.cell_height != 0 and !area.isEmpty();
    const background = modal.rgb(palette.panel_bg) orelse {
        renderer.hide();
        return;
    };
    const accent = modal.rgb(palette.accent) orelse {
        renderer.hide();
        return;
    };
    if (!renderer.frame_usable) {
        renderer.hide();
        return;
    }

    const target_width = std.math.mul(u32, area.w, renderer.cell_width) catch {
        renderer.hide();
        return;
    };
    const target_height = std.math.mul(u32, area.h, renderer.cell_height) catch {
        renderer.hide();
        return;
    };
    const horizontal_width = target_width -| @as(u32, renderer.cell_width) * 2;
    const vertical_height = target_height -| @as(u32, renderer.cell_height) * 2;
    if (horizontal_width == 0 or vertical_height == 0) {
        renderer.hide();
        return;
    }
    const shortest = @min(renderer.cell_width, renderer.cell_height);
    const border_width = @max(@as(u16, 1), shortest / 10);
    const radius = @max(@as(u16, 1), @min(@as(u16, 12), shortest / 2));
    const key: ModalRenderKey = .{
        .target_width = target_width,
        .target_height = target_height,
        .cell_width = renderer.cell_width,
        .cell_height = renderer.cell_height,
        .border_width = border_width,
        .radius = radius,
        .background = background,
        .accent = accent,
    };
    renderer.desired_area = area;
    if (renderer.key != null and std.meta.eql(renderer.key.?, key)) {
        for (&renderer.assets) |*asset| {
            if (!asset.emitted) {
                asset.dirty = true;
            }
        }
        return;
    }

    renderer.cancelPartial();
    const dimensions = [_][2]u32{
        .{ @as(u32, renderer.cell_width) * 4, renderer.cell_height },
        .{ horizontal_width, border_width },
        .{ border_width, vertical_height },
    };
    var total_bytes: usize = 0;
    for (dimensions) |size| {
        const pixels = std.math.mul(usize, size[0], size[1]) catch {
            renderer.hide();
            return;
        };
        const bytes = std.math.mul(usize, pixels, 4) catch {
            renderer.hide();
            return;
        };
        total_bytes = std.math.add(usize, total_bytes, bytes) catch {
            renderer.hide();
            return;
        };
    }
    if (total_bytes > modal.max_cache_bytes) {
        renderer.hide();
        return;
    }
    for (&renderer.assets, dimensions) |*asset, size| {
        const byte_count = @as(usize, size[0]) * size[1] * 4;
        if (asset.pixels.len != byte_count) {
            const next = if (asset.pixels.len == 0)
                renderer.gpa.alloc(u8, byte_count)
            else
                renderer.gpa.realloc(asset.pixels, byte_count);
            asset.pixels = next catch {
                renderer.key = null;
                renderer.hide();
                return;
            };
        }
        asset.width = size[0];
        asset.height = size[1];
    }
    modal.renderCorners(renderer.assetFor(.corners), key);
    modal.fill(renderer.assetFor(.horizontal).pixels, key.accent);
    modal.fill(renderer.assetFor(.vertical).pixels, key.accent);
    renderer.key = key;
    for (&renderer.assets) |*asset| asset.dirty = true;
}

pub fn covers(renderer: *const Renderer, area: RectType) bool {
    if (!renderer.frame_usable or renderer.partial != null or renderer.abort_pending or
        !modal.optionalAreaEql(renderer.desired_area, area) or
        !modal.optionalAreaEql(renderer.emitted_area, area))
    {
        return false;
    }
    for (renderer.assets) |asset| if (asset.dirty or !asset.emitted) return false;
    return true;
}

pub fn damaged(renderer: *const Renderer) bool {
    if (renderer.abort_pending or renderer.partial != null or
        !modal.optionalAreaEql(renderer.desired_area, renderer.emitted_area))
    {
        return true;
    }
    if (!renderer.supported) {
        for (renderer.assets) |asset| if (asset.emitted) return true;
        return false;
    }
    if (renderer.frame_usable) {
        for (renderer.assets) |asset| if (asset.dirty) return true;
    }
    return false;
}

pub fn transferInProgress(renderer: *const Renderer) bool {
    return renderer.abort_pending or renderer.partial != null;
}

pub fn write(renderer: *Renderer, writer: *std.Io.Writer) std.Io.Writer.Error!usize {
    if (!renderer.damaged()) {
        return 0;
    }
    var written: usize = 0;
    if (renderer.abort_pending) {
        written += try writeTransmissionAbort_module(writer);
        renderer.abort_pending = false;
    }
    if (!renderer.supported) {
        for (&renderer.assets, 0..) |*asset, index| {
            if (asset.emitted) {
                written += try writeDeleteImage_module(writer, modal.imageId(index));
            }
            asset.emitted = false;
            asset.dirty = false;
            asset.transfer_offset = 0;
        }
        renderer.emitted_area = null;
        return written;
    }

    if (renderer.emitted_area != null and renderer.anyDirty()) {
        written += try renderer.deletePlacements(writer);
        renderer.emitted_area = null;
    }
    if (renderer.frame_usable) {
        for (&renderer.assets, 0..) |*asset, index| {
            if (!asset.dirty) {
                continue;
            }
            if (asset.emitted) {
                written += try writeDeleteImage_module(writer, modal.imageId(index));
                asset.emitted = false;
            }
            const progress = try kitty_codec.writeTransmissionChunks(writer, .{
                .external_id = modal.imageId(index),
                .image = .{
                    .key = .{ .image_id = modal.imageId(index), .generation = 1 },
                    .format = .rgba,
                    .width = asset.width,
                    .height = asset.height,
                    .byte_len = asset.pixels.len,
                },
                .pixels = asset.pixels,
                .start_offset = asset.transfer_offset,
                .budget = kitty_codec.transmission_budget_per_frame,
                .compressed = false,
            });
            written += progress.written;
            asset.transfer_offset = progress.offset;
            if (progress.offset != asset.pixels.len) {
                renderer.partial = @enumFromInt(index);
                return written;
            }
            asset.transfer_offset = 0;
            asset.dirty = false;
            asset.emitted = true;
            renderer.partial = null;
            return written;
        }
    }

    if (!modal.optionalAreaEql(renderer.desired_area, renderer.emitted_area)) {
        if (renderer.emitted_area != null) {
            written += try renderer.deletePlacements(writer);
        }
        const ready = renderer.allImagesReady();
        if (renderer.desired_area) |area| {
            if (ready) {
                written += try renderer.writePlacements(writer, area);
            }
        }
        renderer.emitted_area = if (ready) renderer.desired_area else null;
    }
    return written;
}

pub fn assetFor(renderer: *Renderer, kind: modal.AssetKind) *Asset {
    return &renderer.assets[@intFromEnum(kind)];
}

fn anyDirty(renderer: *const Renderer) bool {
    for (renderer.assets) |asset| if (asset.dirty) return true;
    return false;
}

fn allImagesReady(renderer: *const Renderer) bool {
    if (!renderer.frame_usable) {
        return false;
    }
    for (renderer.assets) |asset| if (asset.dirty or !asset.emitted) return false;
    return true;
}

fn cancelPartial(renderer: *Renderer) void {
    const kind = renderer.partial orelse return;
    renderer.assetFor(kind).transfer_offset = 0;
    renderer.partial = null;
    renderer.abort_pending = true;
}

fn hide(renderer: *Renderer) void {
    renderer.cancelPartial();
    renderer.frame_usable = false;
    renderer.desired_area = null;
}

fn deletePlacements(renderer: *Renderer, writer: *std.Io.Writer) std.Io.Writer.Error!usize {
    _ = renderer;
    var written: usize = 0;
    for (0..modal.placement_count) |index|
        written += try writeDeletePlacement_module(
            writer,
            modal.placementImageId(index),
            modal.placementId(index),
        );
    return written;
}

fn writePlacements(renderer: *const Renderer, writer: *std.Io.Writer, area: RectType) std.Io.Writer.Error!usize {
    const key = renderer.key.?;
    const horizontal = renderer.assets[@intFromEnum(modal.AssetKind.horizontal)];
    const vertical = renderer.assets[@intFromEnum(modal.AssetKind.vertical)];
    const right = area.x + area.w - 1;
    const bottom = area.y + area.h - 1;
    var written: usize = 0;
    const corner_positions = [_][2]u16{
        .{ area.x, area.y },
        .{ right, area.y },
        .{ area.x, bottom },
        .{ right, bottom },
    };
    for (corner_positions, 0..) |position, index| {
        written += try kitty_codec.writeUiPlacement(writer, .{
            .image_id = modal.imageId(@intFromEnum(modal.AssetKind.corners)),
            .placement_id = modal.placementId(index),
            .value = .{
                .column = position[0],
                .row = position[1],
                .offset_x = 0,
                .offset_y = 0,
                .source_x = @as(u32, @intCast(index)) * key.cell_width,
                .source_y = 0,
                .source_width = key.cell_width,
                .source_height = key.cell_height,
                .columns = 0,
                .rows = 0,
            },
            .z = modal.z_index,
        });
    }
    written += try kitty_codec.writeUiPlacement(writer, .{
        .image_id = modal.imageId(@intFromEnum(modal.AssetKind.horizontal)),
        .placement_id = modal.placementId(4),
        .value = .{
            .column = area.x + 1,
            .row = area.y,
            .offset_x = 0,
            .offset_y = 0,
            .source_x = 0,
            .source_y = 0,
            .source_width = horizontal.width,
            .source_height = horizontal.height,
            .columns = 0,
            .rows = 0,
        },
        .z = modal.z_index,
    });
    written += try kitty_codec.writeUiPlacement(writer, .{
        .image_id = modal.imageId(@intFromEnum(modal.AssetKind.horizontal)),
        .placement_id = modal.placementId(5),
        .value = .{
            .column = area.x + 1,
            .row = bottom,
            .offset_x = 0,
            .offset_y = key.cell_height - key.border_width,
            .source_x = 0,
            .source_y = 0,
            .source_width = horizontal.width,
            .source_height = horizontal.height,
            .columns = 0,
            .rows = 0,
        },
        .z = modal.z_index,
    });
    written += try kitty_codec.writeUiPlacement(writer, .{
        .image_id = modal.imageId(@intFromEnum(modal.AssetKind.vertical)),
        .placement_id = modal.placementId(6),
        .value = .{
            .column = area.x,
            .row = area.y + 1,
            .offset_x = 0,
            .offset_y = 0,
            .source_x = 0,
            .source_y = 0,
            .source_width = vertical.width,
            .source_height = vertical.height,
            .columns = 0,
            .rows = 0,
        },
        .z = modal.z_index,
    });
    written += try kitty_codec.writeUiPlacement(writer, .{
        .image_id = modal.imageId(@intFromEnum(modal.AssetKind.vertical)),
        .placement_id = modal.placementId(7),
        .value = .{
            .column = right,
            .row = area.y + 1,
            .offset_x = key.cell_width - key.border_width,
            .offset_y = 0,
            .source_x = 0,
            .source_y = 0,
            .source_width = vertical.width,
            .source_height = vertical.height,
            .columns = 0,
            .rows = 0,
        },
        .z = modal.z_index,
    });
    return written;
}
