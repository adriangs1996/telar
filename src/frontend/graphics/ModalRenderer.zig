const data = @import("model");
const SidebarRendererInput = @import("SidebarRendererInput.zig");
const core = @import("telar-core");
const kitty_protocol = @import("kitty_protocol");
const std = @import("std");
const modal = @import("modal.zig");
const Asset = @import("Asset.zig");
const ModalRenderKey = @import("ModalRenderKey.zig");
const kitty_codec = @import("kitty_codec.zig");
const Renderer = @This();

gpa: std.mem.Allocator,
assets: [modal.asset_count]Asset = @splat(.{}),
supported: bool = false,
cell_width: u16 = 0,
cell_height: u16 = 0,
key: ?ModalRenderKey = null,
desired_area: ?core.Rect = null,
emitted_area: ?core.Rect = null,
frame_usable: bool = false,
partial: ?modal.AssetKind = null,
abort_pending: bool = false,

pub fn init(gpa: std.mem.Allocator) Renderer {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Renderer) void {
    for (&self.assets) |*asset| if (asset.pixels.len != 0)
        self.gpa.free(asset.pixels);
}

pub fn retainedBytes(self: *const Renderer) usize {
    var total: usize = 0;
    for (self.assets) |asset| total += asset.pixels.len;
    return total;
}

/// Applies host graphics support and cell geometry to modal rendering.
/// For example: `_ = renderer.configure(.{ .support = .supported, .cell_width = 10, .cell_height = 20 });`.
pub fn configure(self: *Renderer, configuration: SidebarRendererInput) bool {
    const supported = configuration.support == .supported;
    if (self.supported == supported and self.cell_width == configuration.cell_width and
        self.cell_height == configuration.cell_height)
    {
        return false;
    }
    self.cancelPartial();
    self.supported = supported;
    self.cell_width = configuration.cell_width;
    self.cell_height = configuration.cell_height;
    self.key = null;
    if (!supported) {
        self.frame_usable = false;
        self.desired_area = null;
    }
    return true;
}

pub fn prepare(self: *Renderer, area: core.Rect, palette: *const data.Palette) void {
    self.frame_usable = self.supported and self.cell_width != 0 and
        self.cell_height != 0 and !area.isEmpty();
    const background = modal.rgb(palette.panel_bg) orelse {
        self.hide();
        return;
    };
    const accent = modal.rgb(palette.accent) orelse {
        self.hide();
        return;
    };
    if (!self.frame_usable) {
        self.hide();
        return;
    }

    const target_width = std.math.mul(u32, area.w, self.cell_width) catch {
        self.hide();
        return;
    };
    const target_height = std.math.mul(u32, area.h, self.cell_height) catch {
        self.hide();
        return;
    };
    const horizontal_width = target_width -| @as(u32, self.cell_width) * 2;
    const vertical_height = target_height -| @as(u32, self.cell_height) * 2;
    if (horizontal_width == 0 or vertical_height == 0) {
        self.hide();
        return;
    }
    const shortest = @min(self.cell_width, self.cell_height);
    const border_width = @max(@as(u16, 1), shortest / 10);
    const radius = @max(@as(u16, 1), @min(@as(u16, 12), shortest / 2));
    const key: ModalRenderKey = .{
        .target_width = target_width,
        .target_height = target_height,
        .cell_width = self.cell_width,
        .cell_height = self.cell_height,
        .border_width = border_width,
        .radius = radius,
        .background = background,
        .accent = accent,
    };
    self.desired_area = area;
    if (self.key != null and std.meta.eql(self.key.?, key)) {
        for (&self.assets) |*asset| {
            if (!asset.emitted) {
                asset.dirty = true;
            }
        }
        return;
    }

    self.cancelPartial();
    const dimensions = [_][2]u32{
        .{ @as(u32, self.cell_width) * 4, self.cell_height },
        .{ horizontal_width, border_width },
        .{ border_width, vertical_height },
    };
    var total_bytes: usize = 0;
    for (dimensions) |size| {
        const pixels = std.math.mul(usize, size[0], size[1]) catch {
            self.hide();
            return;
        };
        const bytes = std.math.mul(usize, pixels, 4) catch {
            self.hide();
            return;
        };
        total_bytes = std.math.add(usize, total_bytes, bytes) catch {
            self.hide();
            return;
        };
    }
    if (total_bytes > modal.max_cache_bytes) {
        self.hide();
        return;
    }
    for (&self.assets, dimensions) |*asset, size| {
        const byte_count = @as(usize, size[0]) * size[1] * 4;
        if (asset.pixels.len != byte_count) {
            const next = if (asset.pixels.len == 0)
                self.gpa.alloc(u8, byte_count)
            else
                self.gpa.realloc(asset.pixels, byte_count);
            asset.pixels = next catch {
                self.key = null;
                self.hide();
                return;
            };
        }
        asset.width = size[0];
        asset.height = size[1];
    }
    modal.renderCorners(self.assetFor(.corners), key);
    modal.fill(self.assetFor(.horizontal).pixels, key.accent);
    modal.fill(self.assetFor(.vertical).pixels, key.accent);
    self.key = key;
    for (&self.assets) |*asset| asset.dirty = true;
}

pub fn covers(self: *const Renderer, area: core.Rect) bool {
    if (!self.frame_usable or self.partial != null or self.abort_pending or
        !modal.optionalAreaEql(self.desired_area, area) or
        !modal.optionalAreaEql(self.emitted_area, area))
    {
        return false;
    }
    for (self.assets) |asset| if (asset.dirty or !asset.emitted) return false;
    return true;
}

pub fn damaged(self: *const Renderer) bool {
    if (self.abort_pending or self.partial != null or
        !modal.optionalAreaEql(self.desired_area, self.emitted_area))
    {
        return true;
    }
    if (!self.supported) {
        for (self.assets) |asset| if (asset.emitted) return true;
        return false;
    }
    if (self.frame_usable) {
        for (self.assets) |asset| if (asset.dirty) return true;
    }
    return false;
}

pub fn transferInProgress(self: *const Renderer) bool {
    return self.abort_pending or self.partial != null;
}

pub fn write(self: *Renderer, writer: *std.Io.Writer) std.Io.Writer.Error!usize {
    if (!self.damaged()) {
        return 0;
    }
    var written: usize = 0;
    if (self.abort_pending) {
        written += try kitty_protocol.writeTransmissionAbort(writer);
        self.abort_pending = false;
    }
    if (!self.supported) {
        for (&self.assets, 0..) |*asset, index| {
            if (asset.emitted) {
                written += try kitty_protocol.writeDeleteImage(writer, modal.imageId(index));
            }
            asset.emitted = false;
            asset.dirty = false;
            asset.transfer_offset = 0;
        }
        self.emitted_area = null;
        return written;
    }

    if (self.emitted_area != null and self.anyDirty()) {
        written += try self.deletePlacements(writer);
        self.emitted_area = null;
    }
    if (self.frame_usable) {
        for (&self.assets, 0..) |*asset, index| {
            if (!asset.dirty) {
                continue;
            }
            if (asset.emitted) {
                written += try kitty_protocol.writeDeleteImage(writer, modal.imageId(index));
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
                self.partial = @enumFromInt(index);
                return written;
            }
            asset.transfer_offset = 0;
            asset.dirty = false;
            asset.emitted = true;
            self.partial = null;
            return written;
        }
    }

    if (!modal.optionalAreaEql(self.desired_area, self.emitted_area)) {
        if (self.emitted_area != null) {
            written += try self.deletePlacements(writer);
        }
        const ready = self.allImagesReady();
        if (self.desired_area) |area| {
            if (ready) {
                written += try self.writePlacements(writer, area);
            }
        }
        self.emitted_area = if (ready) self.desired_area else null;
    }
    return written;
}

pub fn assetFor(self: *Renderer, kind: modal.AssetKind) *Asset {
    return &self.assets[@intFromEnum(kind)];
}

fn anyDirty(self: *const Renderer) bool {
    for (self.assets) |asset| if (asset.dirty) return true;
    return false;
}

fn allImagesReady(self: *const Renderer) bool {
    if (!self.frame_usable) {
        return false;
    }
    for (self.assets) |asset| if (asset.dirty or !asset.emitted) return false;
    return true;
}

fn cancelPartial(self: *Renderer) void {
    const kind = self.partial orelse return;
    self.assetFor(kind).transfer_offset = 0;
    self.partial = null;
    self.abort_pending = true;
}

fn hide(self: *Renderer) void {
    self.cancelPartial();
    self.frame_usable = false;
    self.desired_area = null;
}

fn deletePlacements(self: *Renderer, writer: *std.Io.Writer) std.Io.Writer.Error!usize {
    _ = self;
    var written: usize = 0;
    for (0..modal.placement_count) |index|
        written += try kitty_protocol.writeDeletePlacement(
            writer,
            modal.placementImageId(index),
            modal.placementId(index),
        );
    return written;
}

fn writePlacements(self: *const Renderer, writer: *std.Io.Writer, area: core.Rect) std.Io.Writer.Error!usize {
    const key = self.key.?;
    const horizontal = self.assets[@intFromEnum(modal.AssetKind.horizontal)];
    const vertical = self.assets[@intFromEnum(modal.AssetKind.vertical)];
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
