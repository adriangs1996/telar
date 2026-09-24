const assets = @import("assets");
const textraster = @import("textraster");
const cellgrid = @import("cellgrid");
const data = @import("model");
const SidebarRendererInput = @import("SidebarRendererInput.zig");
const kitty_protocol = @import("kitty_protocol");
const std = @import("std");
const Rasterizer = textraster.Rasterizer;
const icon_graphics = @import("icons.zig");
const toast = @import("toast.zig");
const toast_module = @import("../widgets/toast.zig");
const kitty_codec = @import("kitty_codec.zig");
const Surface = textraster.Surface;
const Renderer = @This();

gpa: std.mem.Allocator,
text: ?Rasterizer,
icons: ?Rasterizer,
supported: bool = false,
media_idle: bool = false,
cell_width: u16 = 0,
cell_height: u16 = 0,
frame_usable: bool = false,
render_deferred: bool = false,
visible_count: u8 = 0,
slots: [data.notifications.max_items]ToastSlot = @splat(.{}),

pub fn init(gpa: std.mem.Allocator) Renderer {
    return .{
        .gpa = gpa,
        .text = Rasterizer.initFont(assets.jetbrains_mono) catch null,
        .icons = Rasterizer.initFont(icon_graphics.embedded_font) catch null,
    };
}

pub fn deinit(self: *Renderer) void {
    for (&self.slots) |*slot| if (slot.pixels.len != 0)
        self.gpa.free(slot.pixels);
    if (self.text) |*text| {
        text.deinit();
    }
    if (self.icons) |*icons| {
        icons.deinit();
    }
}

pub fn retainedBytes(self: *const Renderer) usize {
    var total: usize = 0;
    for (self.slots) |slot| total += slot.pixels.len;
    return total;
}

/// Applies host graphics support and cell geometry to toast rendering.
/// For example: `_ = renderer.configure(.{ .support = .supported, .cell_width = 10, .cell_height = 20 });`.
pub fn configure(self: *Renderer, configuration: SidebarRendererInput) bool {
    const supported = configuration.support == .supported;
    if (self.supported == supported and self.cell_width == configuration.cell_width and
        self.cell_height == configuration.cell_height)
    {
        return false;
    }
    self.supported = supported;
    self.cell_width = configuration.cell_width;
    self.cell_height = configuration.cell_height;
    for (&self.slots) |*slot| {
        slot.key = null;
        slot.failed_key = null;
    }
    return true;
}

pub fn setMediaIdle(self: *Renderer, idle: bool) void {
    self.media_idle = idle;
}

/// Prepares visible toast slots for one themed frame.
/// For example: `renderer.prepare(.{ .area = area, .center = center, .palette = palette });`.
pub fn prepare(self: *Renderer, preparation: Preparation) void {
    for (&self.slots) |*slot| slot.visible = false;
    self.visible_count = 0;
    self.render_deferred = false;
    self.frame_usable = self.supported and self.text != null and
        (preparation.icon_theme != .nerd_font or self.icons != null) and
        self.cell_width != 0 and self.cell_height != 0 and
        !preparation.area.isEmpty();
    const colors = toast.resolveColors(preparation.palette) orelse {
        self.frame_usable = false;
        self.retireInvisible();
        return;
    };
    if (!self.frame_usable) {
        self.retireInvisible();
        return;
    }

    const count = @min(
        @as(usize, preparation.center.count),
        @as(usize, (preparation.area.h + toast_module.card_gap) / (toast_module.card_height + toast_module.card_gap)),
    );
    self.visible_count = @intCast(count);
    // Release the one id that the bounded center may have evicted before
    // assigning a slot to the new front item. Existing ids retain their
    // stable host image ids even though their vertical order changed.
    for (&self.slots) |*slot| {
        if (slot.id == .invalid) {
            continue;
        }
        var retained = false;
        for (0..count) |index| {
            if (preparation.center.itemAt(index).?.id == slot.id) {
                retained = true;
                break;
            }
        }
        if (!retained) {
            slot.id = .invalid;
            slot.key = null;
            slot.failed_key = null;
            slot.placement = null;
            slot.image_dirty = false;
        }
    }
    for (0..count) |index| {
        const item = preparation.center.itemAt(index).?;
        const slot = self.slotFor(item.id) orelse {
            self.frame_usable = false;
            break;
        };
        slot.visible = true;
        const key: ToastRenderKey = .{
            .id = item.id,
            .level = item.level,
            .cell_width = self.cell_width,
            .cell_height = self.cell_height,
            .card_columns = preparation.area.w,
            .icon_theme = preparation.icon_theme,
            .background = colors.surface0,
            .accent = colors.level(item.level),
            .text = colors.text,
            .subtext = colors.subtext,
        };
        if (slot.key == null or !std.meta.eql(slot.key.?, key)) {
            if (!self.media_idle) {
                self.frame_usable = false;
                self.render_deferred = true;
                continue;
            }
            if (slot.failed_key != null and std.meta.eql(slot.failed_key.?, key)) {
                self.frame_usable = false;
                continue;
            }
            self.renderSlot(.{ .slot = slot, .item = item, .key = key }) catch {
                slot.key = null;
                slot.failed_key = key;
                self.frame_usable = false;
                continue;
            };
        }
        const full_width = slot.width;
        const visible_width = item.animatedPixels(full_width);
        const right = (@as(u32, preparation.area.x) + preparation.area.w) * self.cell_width;
        const pixel_x = right -| visible_width;
        const pixel_y = (@as(u32, preparation.area.y) + @as(u32, @intCast(index)) *
            (toast_module.card_height + toast_module.card_gap)) * self.cell_height;
        slot.placement = if (visible_width == 0) null else .{
            .column = pixel_x / self.cell_width,
            .row = pixel_y / self.cell_height,
            .offset_x = pixel_x % self.cell_width,
            .offset_y = pixel_y % self.cell_height,
            .source_x = full_width - visible_width,
            .source_y = 0,
            .source_width = visible_width,
            .source_height = slot.height,
            .columns = 0,
            .rows = 0,
        };
    }
    self.retireInvisible();
}

/// True only after every visible texture and placement reached the host.
/// Until then the composition keeps the complete cell fallback visible.
pub fn coversAll(self: *const Renderer) bool {
    if (!self.frame_usable or self.visible_count == 0) {
        return false;
    }
    var count: u8 = 0;
    for (&self.slots) |*slot| {
        if (!slot.visible) {
            continue;
        }
        count += 1;
        if (!slot.image_emitted or slot.image_dirty) {
            return false;
        }
        if (slot.placement != null and slot.emitted_placement == null) {
            return false;
        }
    }
    return count == self.visible_count;
}

/// The notification center may change before the lower-priority media
/// pass catches up. Never hide the cell fallback for a stale texture set.
pub fn covers(self: *const Renderer, center: *const data.Center) bool {
    if (!self.coversAll() or self.visible_count != center.count) {
        return false;
    }
    for (0..center.count) |index| {
        const id = center.itemAt(index).?.id;
        for (self.slots) |slot| {
            if (slot.id == id and slot.visible and slot.image_emitted and
                !slot.image_dirty)
            {
                break;
            }
        } else return false;
    }
    return true;
}

pub fn damaged(self: *const Renderer) bool {
    if (self.render_deferred) {
        return true;
    }
    if (self.transmissionPending()) {
        return true;
    }
    const placements_enabled = self.allImagesReady();
    for (&self.slots) |*slot| {
        if (slot.transfer_offset != 0) {
            return true;
        }
        if (!self.frame_usable and slot.image_emitted) {
            return true;
        }
        const desired = if (placements_enabled and slot.visible) slot.placement else null;
        if (!toast.optionalPlacementEql(desired, slot.emitted_placement)) {
            return true;
        }
        if (!slot.visible and slot.image_emitted) {
            return true;
        }
    }
    return false;
}

pub fn transmissionPending(self: *const Renderer) bool {
    if (!self.frame_usable) {
        return false;
    }
    for (&self.slots) |slot| if (slot.visible and slot.image_dirty) return true;
    return false;
}

pub fn preparationDeferred(self: *const Renderer) bool {
    return self.render_deferred;
}

pub fn transferInProgress(self: *const Renderer) bool {
    for (self.slots) |slot| if (slot.transfer_offset != 0) return true;
    return false;
}

/// True when the remaining toast work cannot emit anything until the
/// client has been idle long enough to rasterize a replacement texture.
pub fn waitingForMediaIdle(self: *const Renderer) bool {
    if (!self.render_deferred) {
        return false;
    }
    const placements_enabled = self.allImagesReady();
    for (self.slots) |slot| {
        if (slot.transfer_offset != 0) {
            return false;
        }
        if ((!slot.visible or slot.image_dirty or !self.frame_usable) and
            slot.image_emitted)
        {
            return false;
        }
        const desired = if (placements_enabled and slot.visible) slot.placement else null;
        if (!toast.optionalPlacementEql(desired, slot.emitted_placement)) {
            return false;
        }
    }
    return true;
}

/// Deletions and placements are always cheap enough to emit. A new image
/// is sent only when the pane-media writer used no budget in this pass.
pub fn write(self: *Renderer, writer: *std.Io.Writer, allow_transmission: bool) std.Io.Writer.Error!usize {
    var written: usize = 0;
    for (&self.slots, 0..) |*slot, index| {
        const transfer_stale = slot.transfer_offset != 0 and
            (!slot.visible or !self.frame_usable or slot.key == null or
                slot.transfer_key == null or
                !std.meta.eql(slot.transfer_key.?, slot.key.?));
        if (transfer_stale) {
            written += try kitty_protocol.writeTransmissionAbort(writer);
            slot.transfer_offset = 0;
            slot.transfer_key = null;
        }
        if ((!slot.visible or slot.image_dirty or !self.frame_usable) and
            slot.image_emitted)
        {
            written += try kitty_protocol.writeDeleteImage(writer, toast.imageId(index));
            slot.image_emitted = false;
            slot.emitted_placement = null;
            if (self.render_deferred and slot.visible and slot.key != null) {
                slot.image_dirty = true;
            }
        }
    }

    if ((allow_transmission or self.transferInProgress()) and
        self.frame_usable)
    transmit: {
        for (&self.slots, 0..) |*slot, index| {
            if (!slot.visible or !slot.image_dirty or slot.key == null) {
                continue;
            }
            if (slot.transfer_offset == 0) {
                slot.transfer_key = slot.key;
            }
            const progress = try kitty_codec.writeTransmissionChunks(writer, .{
                .external_id = toast.imageId(index),
                .image = .{
                    .key = .{ .image_id = toast.imageId(index), .generation = 1 },
                    .format = .rgba,
                    .width = slot.width,
                    .height = slot.height,
                    .byte_len = slot.pixels.len,
                },
                .pixels = slot.pixels,
                .start_offset = slot.transfer_offset,
                .budget = kitty_codec.transmission_budget_per_frame,
                .compressed = false,
            });
            written += progress.written;
            slot.transfer_offset = progress.offset;
            if (progress.offset == slot.pixels.len) {
                slot.transfer_offset = 0;
                slot.transfer_key = null;
                slot.image_dirty = false;
                slot.image_emitted = true;
            }
            break :transmit;
        }
    }

    const placements_enabled = self.allImagesReady();
    for (&self.slots, 0..) |*slot, index| {
        const desired = if (placements_enabled and slot.visible) slot.placement else null;
        if (toast.optionalPlacementEql(desired, slot.emitted_placement)) {
            continue;
        }
        if (slot.emitted_placement != null) {
            written += try kitty_protocol.writeDeletePlacement(
                writer,
                toast.imageId(index),
                toast.placementId(index),
            );
        }
        if (desired) |placement| {
            written += try kitty_codec.writePlacement(writer, .{
                .image_id = toast.imageId(index),
                .placement_id = toast.placementId(index),
                .value = placement,
                .z = toast.toast_z_index,
            });
        }
        slot.emitted_placement = desired;
    }
    return written;
}

fn slotFor(self: *Renderer, id: data.NotificationId) ?*ToastSlot {
    for (&self.slots) |*slot| if (slot.id == id) return slot;
    for (&self.slots) |*slot| {
        if (slot.visible or slot.id != .invalid) {
            continue;
        }
        slot.id = id;
        return slot;
    }
    for (&self.slots) |*slot| {
        if (slot.visible) {
            continue;
        }
        slot.id = id;
        slot.key = null;
        slot.failed_key = null;
        slot.placement = null;
        slot.image_dirty = false;
        return slot;
    }
    return null;
}

fn retireInvisible(self: *Renderer) void {
    for (&self.slots) |*slot| {
        if (slot.visible) {
            continue;
        }
        slot.id = .invalid;
        slot.key = null;
        slot.failed_key = null;
        slot.placement = null;
        slot.image_dirty = false;
    }
}

fn renderSlot(self: *Renderer, rendering: SlotRender) !void {
    const slot = rendering.slot;
    const item = rendering.item;
    const key = rendering.key;

    const width = std.math.mul(u32, key.card_columns, self.cell_width) catch
        return error.ToastTooLarge;
    const height = std.math.mul(u32, toast_module.card_height, self.cell_height) catch
        return error.ToastTooLarge;
    const pixel_count = std.math.mul(usize, width, height) catch
        return error.ToastTooLarge;
    const byte_count = std.math.mul(usize, pixel_count, 4) catch
        return error.ToastTooLarge;
    if (byte_count > toast.max_image_bytes) {
        return error.ToastTooLarge;
    }
    if (slot.pixels.len != byte_count) {
        if (slot.pixels.len == 0) {
            slot.pixels = try self.gpa.alloc(u8, byte_count);
        } else {
            slot.pixels = try self.gpa.realloc(slot.pixels, byte_count);
        }
    }
    slot.width = width;
    slot.height = height;
    const surface: Surface = .{
        .pixels = slot.pixels,
        .width = width,
        .height = height,
    };
    toast.fill(surface, .{ key.background[0], key.background[1], key.background[2], 255 });
    const accent = toast.rasterColor(key.accent);
    const border = @min(
        @max(@as(u32, 1), self.cell_width / 8),
        @max(@as(u32, 1), @min(width, height) / 2),
    );
    toast.fillRect(surface, .{ .x = 0, .y = 0, .width = width, .height = border }, accent);
    toast.fillRect(surface, .{ .x = 0, .y = height - border, .width = width, .height = border }, accent);
    toast.fillRect(surface, .{ .x = 0, .y = 0, .width = border, .height = height }, accent);
    toast.fillRect(surface, .{ .x = width - border, .y = 0, .width = border, .height = height }, accent);
    toast.fillRect(surface, .{
        .x = border,
        .y = border,
        .width = @max(border, self.cell_width / 3),
        .height = height - border * 2,
    }, accent);

    const font_height: u16 = @intCast(std.math.clamp(
        @as(u32, self.cell_height) * 3 / 4,
        6,
        64,
    ));
    const text = &self.text.?;
    try text.setPixelHeight(font_height);
    const metrics = text.metrics();
    const left = @as(i32, self.cell_width) * 2;
    const right_padding = @as(u32, self.cell_width) * 4;
    const max_text_width = width -| @as(u32, @intCast(left)) -| right_padding;
    _ = try text.drawText(.{
        .surface = surface,
        .origin = .{ .x = left, .y = toast.baseline(metrics, 0, self.cell_height) },
        .text = item.title(),
        .color = accent,
        .max_width = max_text_width,
    });
    _ = try text.drawText(.{
        .surface = surface,
        .origin = .{ .x = left, .y = toast.baseline(metrics, self.cell_height, self.cell_height) },
        .text = item.message(),
        .color = toast.rasterColor(key.text),
        .max_width = width -| @as(u32, @intCast(left)) -| @as(u32, self.cell_width) * 2,
    });
    const hint = if (item.clickable()) "click to open" else "click to dismiss";
    _ = try text.drawText(.{
        .surface = surface,
        .origin = .{ .x = left, .y = toast.baseline(metrics, @as(u32, self.cell_height) * 2, self.cell_height) },
        .text = hint,
        .color = toast.rasterColor(key.subtext),
        .max_width = width -| @as(u32, @intCast(left)) -| @as(u32, self.cell_width) * 2,
    });
    const close_x: i32 = @intCast(width -| @as(u32, self.cell_width) * 3);
    if (key.icon_theme == .nerd_font) {
        const icons = &self.icons.?;
        try icons.setPixelHeight(font_height);
        _ = try icons.drawText(.{
            .surface = surface,
            .origin = .{ .x = close_x, .y = toast.baseline(icons.metrics(), 0, self.cell_height) },
            .text = data.icons.Icon.close.nerdGlyph(),
            .color = accent,
            .max_width = @as(u32, self.cell_width) * 2,
        });
    } else {
        _ = try text.drawText(.{
            .surface = surface,
            .origin = .{ .x = close_x, .y = toast.baseline(metrics, 0, self.cell_height) },
            .text = data.icons.Icon.close.unicodeGlyph(),
            .color = accent,
            .max_width = @as(u32, self.cell_width) * 2,
        });
    }
    slot.key = key;
    slot.failed_key = null;
    slot.image_dirty = true;
}

fn allImagesReady(self: *const Renderer) bool {
    if (!self.frame_usable or self.visible_count == 0) {
        return false;
    }
    var count: u8 = 0;
    for (&self.slots) |slot| {
        if (!slot.visible) {
            continue;
        }
        count += 1;
        if (slot.key == null or slot.image_dirty or !slot.image_emitted) {
            return false;
        }
    }
    return count == self.visible_count;
}

const SlotRender = struct {
    slot: *ToastSlot,
    item: *const data.NotificationItem,
    key: ToastRenderKey,
};

const ToastSlot = struct {
    id: data.NotificationId = .invalid,
    pixels: []u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    key: ?ToastRenderKey = null,
    failed_key: ?ToastRenderKey = null,
    placement: ?kitty_protocol.OutputPlacement = null,
    emitted_placement: ?kitty_protocol.OutputPlacement = null,
    visible: bool = false,
    image_dirty: bool = false,
    image_emitted: bool = false,
    transfer_offset: usize = 0,
    transfer_key: ?ToastRenderKey = null,
};

const Preparation = struct {
    area: cellgrid.Rect,
    center: *const data.Center,
    palette: *const data.Palette,
    icon_theme: data.icons.Theme = .unicode,
};

const ToastRenderKey = struct {
    id: data.NotificationId,
    level: data.NotificationLevel,
    cell_width: u16,
    cell_height: u16,
    card_columns: u16,
    icon_theme: data.icons.Theme,
    background: [3]u8,
    accent: [3]u8,
    text: [3]u8,
    subtext: [3]u8,
};
