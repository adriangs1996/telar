const Renderer = @This();
const std = @import("std");
const source_namespace = @import("modal.zig");
const Asset = @import("Asset.zig");
const RenderKey = @import("ModalRenderKey.zig");
const kitty = @import("kitty.zig");
const theme = @import("../ui/root.zig").theme;
gpa: std.mem.Allocator,
assets: [source_namespace.asset_count]Asset = @splat(.{}),
supported: bool = false,
cell_width: u16 = 0,
cell_height: u16 = 0,
key: ?RenderKey = null,
desired_area: ?source_namespace.ui.Rect = null,
emitted_area: ?source_namespace.ui.Rect = null,
frame_usable: bool = false,
partial: ?source_namespace.AssetKind = null,
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
pub fn configure(renderer: *Renderer, configuration: kitty.Configuration) bool {
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

pub fn prepare(renderer: *Renderer, area: source_namespace.ui.Rect, palette: *const theme.Palette) void {
    renderer.frame_usable = renderer.supported and renderer.cell_width != 0 and
        renderer.cell_height != 0 and !area.isEmpty();
    const background = source_namespace.rgb(palette.panel_bg) orelse {
        renderer.hide();
        return;
    };
    const accent = source_namespace.rgb(palette.accent) orelse {
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
    const key: RenderKey = .{
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
    if (total_bytes > source_namespace.max_cache_bytes) {
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
    source_namespace.renderCorners(renderer.assetFor(.corners), key);
    source_namespace.fill(renderer.assetFor(.horizontal).pixels, key.accent);
    source_namespace.fill(renderer.assetFor(.vertical).pixels, key.accent);
    renderer.key = key;
    for (&renderer.assets) |*asset| asset.dirty = true;
}

pub fn covers(renderer: *const Renderer, area: source_namespace.ui.Rect) bool {
    if (!renderer.frame_usable or renderer.partial != null or renderer.abort_pending or
        !source_namespace.optionalAreaEql(renderer.desired_area, area) or
        !source_namespace.optionalAreaEql(renderer.emitted_area, area))
    {
        return false;
    }
    for (renderer.assets) |asset| if (asset.dirty or !asset.emitted) return false;
    return true;
}

pub fn damaged(renderer: *const Renderer) bool {
    if (renderer.abort_pending or renderer.partial != null or
        !source_namespace.optionalAreaEql(renderer.desired_area, renderer.emitted_area))
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

pub fn write(renderer: *Renderer, writer: *source_namespace.Io.Writer) source_namespace.Io.Writer.Error!usize {
    if (!renderer.damaged()) {
        return 0;
    }
    var written: usize = 0;
    if (renderer.abort_pending) {
        written += try kitty.writeTransmissionAbort(writer);
        renderer.abort_pending = false;
    }
    if (!renderer.supported) {
        for (&renderer.assets, 0..) |*asset, index| {
            if (asset.emitted) {
                written += try kitty.writeDeleteImage(writer, source_namespace.imageId(index));
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
                written += try kitty.writeDeleteImage(writer, source_namespace.imageId(index));
                asset.emitted = false;
            }
            const progress = try kitty.writeTransmissionChunks(writer, .{
                .external_id = source_namespace.imageId(index),
                .image = .{
                    .key = .{ .image_id = source_namespace.imageId(index), .generation = 1 },
                    .format = .rgba,
                    .width = asset.width,
                    .height = asset.height,
                    .byte_len = asset.pixels.len,
                },
                .pixels = asset.pixels,
                .start_offset = asset.transfer_offset,
                .budget = kitty.transmission_budget_per_frame,
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

    if (!source_namespace.optionalAreaEql(renderer.desired_area, renderer.emitted_area)) {
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

pub fn assetFor(renderer: *Renderer, kind: source_namespace.AssetKind) *Asset {
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

fn deletePlacements(renderer: *Renderer, writer: *source_namespace.Io.Writer) source_namespace.Io.Writer.Error!usize {
    _ = renderer;
    var written: usize = 0;
    for (0..source_namespace.placement_count) |index|
        written += try kitty.writeDeletePlacement(
            writer,
            source_namespace.placementImageId(index),
            source_namespace.placementId(index),
        );
    return written;
}

fn writePlacements(renderer: *const Renderer, writer: *source_namespace.Io.Writer, area: source_namespace.ui.Rect) source_namespace.Io.Writer.Error!usize {
    const key = renderer.key.?;
    const horizontal = renderer.assets[@intFromEnum(source_namespace.AssetKind.horizontal)];
    const vertical = renderer.assets[@intFromEnum(source_namespace.AssetKind.vertical)];
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
        written += try kitty.writeUiPlacement(writer, .{
            .image_id = source_namespace.imageId(@intFromEnum(source_namespace.AssetKind.corners)),
            .placement_id = source_namespace.placementId(index),
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
            .z = source_namespace.z_index,
        });
    }
    written += try kitty.writeUiPlacement(writer, .{
        .image_id = source_namespace.imageId(@intFromEnum(source_namespace.AssetKind.horizontal)),
        .placement_id = source_namespace.placementId(4),
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
        .z = source_namespace.z_index,
    });
    written += try kitty.writeUiPlacement(writer, .{
        .image_id = source_namespace.imageId(@intFromEnum(source_namespace.AssetKind.horizontal)),
        .placement_id = source_namespace.placementId(5),
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
        .z = source_namespace.z_index,
    });
    written += try kitty.writeUiPlacement(writer, .{
        .image_id = source_namespace.imageId(@intFromEnum(source_namespace.AssetKind.vertical)),
        .placement_id = source_namespace.placementId(6),
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
        .z = source_namespace.z_index,
    });
    written += try kitty.writeUiPlacement(writer, .{
        .image_id = source_namespace.imageId(@intFromEnum(source_namespace.AssetKind.vertical)),
        .placement_id = source_namespace.placementId(7),
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
        .z = source_namespace.z_index,
    });
    return written;
}
