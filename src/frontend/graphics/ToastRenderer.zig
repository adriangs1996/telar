const std = @import("std");
const RasterizerType = @import("Rasterizer.zig");
const max_items_module = @import("telar-client").max_items;
const ToastSlot = @import("ToastSlot.zig");
const icon_graphics = @import("icons.zig");
const ConfigurationType = @import("Configuration.zig");
const Preparation = @import("Preparation.zig");
const toast = @import("toast.zig");
const toast_module = @import("../widgets/toast.zig");
const ToastRenderKey = @import("ToastRenderKey.zig");
const CenterType = @import("telar-client").Center;
const writeTransmissionAbort_module = @import("kitty_protocol").writeTransmissionAbort;
const writeDeleteImage_module = @import("kitty_protocol").writeDeleteImage;
const kitty_codec = @import("kitty_codec.zig");
const writeDeletePlacement_module = @import("kitty_protocol").writeDeletePlacement;
const IdType = @import("telar-client").Id;
const SlotRender = @import("SlotRender.zig");
const SurfaceType = @import("Surface.zig");
const IconType = @import("telar-client").Icon;
const Renderer = @This();

gpa: std.mem.Allocator,
text: ?RasterizerType,
icons: ?RasterizerType,
supported: bool = false,
media_idle: bool = false,
cell_width: u16 = 0,
cell_height: u16 = 0,
frame_usable: bool = false,
render_deferred: bool = false,
visible_count: u8 = 0,
slots: [max_items_module]ToastSlot = @splat(.{}),

pub fn init(gpa: std.mem.Allocator) Renderer {
    return .{
        .gpa = gpa,
        .text = RasterizerType.init() catch null,
        .icons = RasterizerType.initFont(icon_graphics.embedded_font) catch null,
    };
}

pub fn deinit(renderer: *Renderer) void {
    for (&renderer.slots) |*slot| if (slot.pixels.len != 0)
        renderer.gpa.free(slot.pixels);
    if (renderer.text) |*text| {
        text.deinit();
    }
    if (renderer.icons) |*icons| {
        icons.deinit();
    }
}

pub fn retainedBytes(renderer: *const Renderer) usize {
    var total: usize = 0;
    for (renderer.slots) |slot| total += slot.pixels.len;
    return total;
}

/// Applies host graphics support and cell geometry to toast rendering.
/// For example: `_ = renderer.configure(.{ .support = .supported, .cell_width = 10, .cell_height = 20 });`.
pub fn configure(renderer: *Renderer, configuration: ConfigurationType) bool {
    const supported = configuration.support == .supported;
    if (renderer.supported == supported and renderer.cell_width == configuration.cell_width and
        renderer.cell_height == configuration.cell_height)
    {
        return false;
    }
    renderer.supported = supported;
    renderer.cell_width = configuration.cell_width;
    renderer.cell_height = configuration.cell_height;
    for (&renderer.slots) |*slot| {
        slot.key = null;
        slot.failed_key = null;
    }
    return true;
}

pub fn setMediaIdle(renderer: *Renderer, idle: bool) void {
    renderer.media_idle = idle;
}

/// Prepares visible toast slots for one themed frame.
/// For example: `renderer.prepare(.{ .area = area, .center = center, .palette = palette });`.
pub fn prepare(renderer: *Renderer, preparation: Preparation) void {
    for (&renderer.slots) |*slot| slot.visible = false;
    renderer.visible_count = 0;
    renderer.render_deferred = false;
    renderer.frame_usable = renderer.supported and renderer.text != null and
        (preparation.icon_theme != .nerd_font or renderer.icons != null) and
        renderer.cell_width != 0 and renderer.cell_height != 0 and
        !preparation.area.isEmpty();
    const colors = toast.resolveColors(preparation.palette) orelse {
        renderer.frame_usable = false;
        renderer.retireInvisible();
        return;
    };
    if (!renderer.frame_usable) {
        renderer.retireInvisible();
        return;
    }

    const count = @min(
        @as(usize, preparation.center.count),
        @as(usize, (preparation.area.h + toast_module.card_gap) / (toast_module.card_height + toast_module.card_gap)),
    );
    renderer.visible_count = @intCast(count);
    // Release the one id that the bounded center may have evicted before
    // assigning a slot to the new front item. Existing ids retain their
    // stable host image ids even though their vertical order changed.
    for (&renderer.slots) |*slot| {
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
        const slot = renderer.slotFor(item.id) orelse {
            renderer.frame_usable = false;
            break;
        };
        slot.visible = true;
        const key: ToastRenderKey = .{
            .id = item.id,
            .level = item.level,
            .cell_width = renderer.cell_width,
            .cell_height = renderer.cell_height,
            .card_columns = preparation.area.w,
            .icon_theme = preparation.icon_theme,
            .background = colors.surface0,
            .accent = colors.level(item.level),
            .text = colors.text,
            .subtext = colors.subtext,
        };
        if (slot.key == null or !std.meta.eql(slot.key.?, key)) {
            if (!renderer.media_idle) {
                renderer.frame_usable = false;
                renderer.render_deferred = true;
                continue;
            }
            if (slot.failed_key != null and std.meta.eql(slot.failed_key.?, key)) {
                renderer.frame_usable = false;
                continue;
            }
            renderer.renderSlot(.{ .slot = slot, .item = item, .key = key }) catch {
                slot.key = null;
                slot.failed_key = key;
                renderer.frame_usable = false;
                continue;
            };
        }
        const full_width = slot.width;
        const visible_width = item.animatedPixels(full_width);
        const right = (@as(u32, preparation.area.x) + preparation.area.w) * renderer.cell_width;
        const pixel_x = right -| visible_width;
        const pixel_y = (@as(u32, preparation.area.y) + @as(u32, @intCast(index)) *
            (toast_module.card_height + toast_module.card_gap)) * renderer.cell_height;
        slot.placement = if (visible_width == 0) null else .{
            .column = pixel_x / renderer.cell_width,
            .row = pixel_y / renderer.cell_height,
            .offset_x = pixel_x % renderer.cell_width,
            .offset_y = pixel_y % renderer.cell_height,
            .source_x = full_width - visible_width,
            .source_y = 0,
            .source_width = visible_width,
            .source_height = slot.height,
            .columns = 0,
            .rows = 0,
        };
    }
    renderer.retireInvisible();
}

/// True only after every visible texture and placement reached the host.
/// Until then the composition keeps the complete cell fallback visible.
pub fn coversAll(renderer: *const Renderer) bool {
    if (!renderer.frame_usable or renderer.visible_count == 0) {
        return false;
    }
    var count: u8 = 0;
    for (&renderer.slots) |*slot| {
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
    return count == renderer.visible_count;
}

/// The notification center may change before the lower-priority media
/// pass catches up. Never hide the cell fallback for a stale texture set.
pub fn covers(renderer: *const Renderer, center: *const CenterType) bool {
    if (!renderer.coversAll() or renderer.visible_count != center.count) {
        return false;
    }
    for (0..center.count) |index| {
        const id = center.itemAt(index).?.id;
        for (renderer.slots) |slot| {
            if (slot.id == id and slot.visible and slot.image_emitted and
                !slot.image_dirty)
            {
                break;
            }
        } else return false;
    }
    return true;
}

pub fn damaged(renderer: *const Renderer) bool {
    if (renderer.render_deferred) {
        return true;
    }
    if (renderer.transmissionPending()) {
        return true;
    }
    const placements_enabled = renderer.allImagesReady();
    for (&renderer.slots) |*slot| {
        if (slot.transfer_offset != 0) {
            return true;
        }
        if (!renderer.frame_usable and slot.image_emitted) {
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

pub fn transmissionPending(renderer: *const Renderer) bool {
    if (!renderer.frame_usable) {
        return false;
    }
    for (&renderer.slots) |slot| if (slot.visible and slot.image_dirty) return true;
    return false;
}

pub fn preparationDeferred(renderer: *const Renderer) bool {
    return renderer.render_deferred;
}

pub fn transferInProgress(renderer: *const Renderer) bool {
    for (renderer.slots) |slot| if (slot.transfer_offset != 0) return true;
    return false;
}

/// True when the remaining toast work cannot emit anything until the
/// client has been idle long enough to rasterize a replacement texture.
pub fn waitingForMediaIdle(renderer: *const Renderer) bool {
    if (!renderer.render_deferred) {
        return false;
    }
    const placements_enabled = renderer.allImagesReady();
    for (renderer.slots) |slot| {
        if (slot.transfer_offset != 0) {
            return false;
        }
        if ((!slot.visible or slot.image_dirty or !renderer.frame_usable) and
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
pub fn write(renderer: *Renderer, writer: *std.Io.Writer, allow_transmission: bool) std.Io.Writer.Error!usize {
    var written: usize = 0;
    for (&renderer.slots, 0..) |*slot, index| {
        const transfer_stale = slot.transfer_offset != 0 and
            (!slot.visible or !renderer.frame_usable or slot.key == null or
                slot.transfer_key == null or
                !std.meta.eql(slot.transfer_key.?, slot.key.?));
        if (transfer_stale) {
            written += try writeTransmissionAbort_module(writer);
            slot.transfer_offset = 0;
            slot.transfer_key = null;
        }
        if ((!slot.visible or slot.image_dirty or !renderer.frame_usable) and
            slot.image_emitted)
        {
            written += try writeDeleteImage_module(writer, toast.imageId(index));
            slot.image_emitted = false;
            slot.emitted_placement = null;
            if (renderer.render_deferred and slot.visible and slot.key != null) {
                slot.image_dirty = true;
            }
        }
    }

    if ((allow_transmission or renderer.transferInProgress()) and
        renderer.frame_usable)
    transmit: {
        for (&renderer.slots, 0..) |*slot, index| {
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

    const placements_enabled = renderer.allImagesReady();
    for (&renderer.slots, 0..) |*slot, index| {
        const desired = if (placements_enabled and slot.visible) slot.placement else null;
        if (toast.optionalPlacementEql(desired, slot.emitted_placement)) {
            continue;
        }
        if (slot.emitted_placement != null) {
            written += try writeDeletePlacement_module(
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

fn slotFor(renderer: *Renderer, id: IdType) ?*ToastSlot {
    for (&renderer.slots) |*slot| if (slot.id == id) return slot;
    for (&renderer.slots) |*slot| {
        if (slot.visible or slot.id != .invalid) {
            continue;
        }
        slot.id = id;
        return slot;
    }
    for (&renderer.slots) |*slot| {
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

fn retireInvisible(renderer: *Renderer) void {
    for (&renderer.slots) |*slot| {
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

fn renderSlot(renderer: *Renderer, rendering: SlotRender) !void {
    const slot = rendering.slot;
    const item = rendering.item;
    const key = rendering.key;

    const width = std.math.mul(u32, key.card_columns, renderer.cell_width) catch
        return error.ToastTooLarge;
    const height = std.math.mul(u32, toast_module.card_height, renderer.cell_height) catch
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
            slot.pixels = try renderer.gpa.alloc(u8, byte_count);
        } else {
            slot.pixels = try renderer.gpa.realloc(slot.pixels, byte_count);
        }
    }
    slot.width = width;
    slot.height = height;
    const surface: SurfaceType = .{
        .pixels = slot.pixels,
        .width = width,
        .height = height,
    };
    toast.fill(surface, .{ key.background[0], key.background[1], key.background[2], 255 });
    const accent = toast.rasterColor(key.accent);
    const border = @min(
        @max(@as(u32, 1), renderer.cell_width / 8),
        @max(@as(u32, 1), @min(width, height) / 2),
    );
    toast.fillRect(surface, .{ .x = 0, .y = 0, .width = width, .height = border }, accent);
    toast.fillRect(surface, .{ .x = 0, .y = height - border, .width = width, .height = border }, accent);
    toast.fillRect(surface, .{ .x = 0, .y = 0, .width = border, .height = height }, accent);
    toast.fillRect(surface, .{ .x = width - border, .y = 0, .width = border, .height = height }, accent);
    toast.fillRect(surface, .{
        .x = border,
        .y = border,
        .width = @max(border, renderer.cell_width / 3),
        .height = height - border * 2,
    }, accent);

    const font_height: u16 = @intCast(std.math.clamp(
        @as(u32, renderer.cell_height) * 3 / 4,
        6,
        64,
    ));
    const text = &renderer.text.?;
    try text.setPixelHeight(font_height);
    const metrics = text.metrics();
    const left = @as(i32, renderer.cell_width) * 2;
    const right_padding = @as(u32, renderer.cell_width) * 4;
    const max_text_width = width -| @as(u32, @intCast(left)) -| right_padding;
    _ = try text.drawText(.{
        .surface = surface,
        .origin = .{ .x = left, .y = toast.baseline(metrics, 0, renderer.cell_height) },
        .text = item.title(),
        .color = accent,
        .max_width = max_text_width,
    });
    _ = try text.drawText(.{
        .surface = surface,
        .origin = .{ .x = left, .y = toast.baseline(metrics, renderer.cell_height, renderer.cell_height) },
        .text = item.message(),
        .color = toast.rasterColor(key.text),
        .max_width = width -| @as(u32, @intCast(left)) -| @as(u32, renderer.cell_width) * 2,
    });
    const hint = if (item.clickable()) "click to open" else "click to dismiss";
    _ = try text.drawText(.{
        .surface = surface,
        .origin = .{ .x = left, .y = toast.baseline(metrics, @as(u32, renderer.cell_height) * 2, renderer.cell_height) },
        .text = hint,
        .color = toast.rasterColor(key.subtext),
        .max_width = width -| @as(u32, @intCast(left)) -| @as(u32, renderer.cell_width) * 2,
    });
    const close_x: i32 = @intCast(width -| @as(u32, renderer.cell_width) * 3);
    if (key.icon_theme == .nerd_font) {
        const icons = &renderer.icons.?;
        try icons.setPixelHeight(font_height);
        _ = try icons.drawText(.{
            .surface = surface,
            .origin = .{ .x = close_x, .y = toast.baseline(icons.metrics(), 0, renderer.cell_height) },
            .text = IconType.close.nerdGlyph(),
            .color = accent,
            .max_width = @as(u32, renderer.cell_width) * 2,
        });
    } else {
        _ = try text.drawText(.{
            .surface = surface,
            .origin = .{ .x = close_x, .y = toast.baseline(metrics, 0, renderer.cell_height) },
            .text = IconType.close.unicodeGlyph(),
            .color = accent,
            .max_width = @as(u32, renderer.cell_width) * 2,
        });
    }
    slot.key = key;
    slot.failed_key = null;
    slot.image_dirty = true;
}

fn allImagesReady(renderer: *const Renderer) bool {
    if (!renderer.frame_usable or renderer.visible_count == 0) {
        return false;
    }
    var count: u8 = 0;
    for (&renderer.slots) |slot| {
        if (!slot.visible) {
            continue;
        }
        count += 1;
        if (slot.key == null or slot.image_dirty or !slot.image_emitted) {
            return false;
        }
    }
    return count == renderer.visible_count;
}
