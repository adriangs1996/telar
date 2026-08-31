//! Client-owned KGP rendering for notifications.
//!
//! Ownership: disposable client presentation state. Authority: the bounded
//! notification center. Budget: at most four 1.5 MiB RGBA images, at most 256
//! KiB of encoded image data per media pass, and placement-only updates while
//! animating. Any media failure removes every placement and leaves the cell
//! renderer fully functional.

const std = @import("std");
const core = @import("telar-core");
const icon_graphics = @import("icons.zig");
const kitty = @import("kitty.zig");
const raster = @import("rasterizer.zig");
const ui_icons = @import("../ui/root.zig").icons;
const theme = @import("../ui/root.zig").theme;
const widgets = @import("../widgets/root.zig");
const notifications = @import("../notifications/root.zig");
const toast = widgets.toast;

const ui = core.ui;

pub const max_image_bytes: usize = 1536 * 1024;
pub const idle_after_ns: u64 = 250 * std.time.ns_per_ms;
const first_image_id: u32 = 0x80001000;
const first_placement_id: u32 = 0x80001100;
const toast_z_index: i32 = 1000;

const RenderKey = struct {
    id: notifications.Id,
    level: notifications.Level,
    cell_width: u16,
    cell_height: u16,
    card_columns: u16,
    icon_theme: ui_icons.Theme,
    background: [3]u8,
    accent: [3]u8,
    text: [3]u8,
    subtext: [3]u8,
};

const Slot = struct {
    id: notifications.Id = .invalid,
    pixels: []u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    key: ?RenderKey = null,
    failed_key: ?RenderKey = null,
    placement: ?kitty.OutputPlacement = null,
    emitted_placement: ?kitty.OutputPlacement = null,
    visible: bool = false,
    image_dirty: bool = false,
    image_emitted: bool = false,
    transfer_offset: usize = 0,
    transfer_key: ?RenderKey = null,
};

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    text: ?raster.Rasterizer,
    icons: ?raster.Rasterizer,
    supported: bool = false,
    media_idle: bool = false,
    cell_width: u16 = 0,
    cell_height: u16 = 0,
    frame_usable: bool = false,
    render_deferred: bool = false,
    visible_count: u8 = 0,
    slots: [notifications.max_items]Slot = @splat(.{}),

    pub fn init(gpa: std.mem.Allocator) Renderer {
        return .{
            .gpa = gpa,
            .text = raster.Rasterizer.init() catch null,
            .icons = raster.Rasterizer.initFont(icon_graphics.embedded_font) catch null,
        };
    }

    pub fn deinit(renderer: *Renderer) void {
        for (&renderer.slots) |*slot| if (slot.pixels.len != 0)
            renderer.gpa.free(slot.pixels);
        if (renderer.text) |*text| text.deinit();
        if (renderer.icons) |*icons| icons.deinit();
    }

    pub fn retainedBytes(renderer: *const Renderer) usize {
        var total: usize = 0;
        for (renderer.slots) |slot| total += slot.pixels.len;
        return total;
    }

    pub fn configure(
        renderer: *Renderer,
        support: kitty.Support,
        cell_width: u16,
        cell_height: u16,
    ) bool {
        const supported = support == .supported;
        if (renderer.supported == supported and renderer.cell_width == cell_width and
            renderer.cell_height == cell_height) return false;
        renderer.supported = supported;
        renderer.cell_width = cell_width;
        renderer.cell_height = cell_height;
        for (&renderer.slots) |*slot| {
            slot.key = null;
            slot.failed_key = null;
        }
        return true;
    }

    pub fn setMediaIdle(renderer: *Renderer, idle: bool) void {
        renderer.media_idle = idle;
    }

    pub fn prepare(
        renderer: *Renderer,
        area: ui.Rect,
        center: *const notifications.Center,
        palette: *const theme.Palette,
    ) void {
        renderer.prepareThemed(area, center, palette, .unicode);
    }

    pub fn prepareThemed(
        renderer: *Renderer,
        area: ui.Rect,
        center: *const notifications.Center,
        palette: *const theme.Palette,
        icon_theme: ui_icons.Theme,
    ) void {
        for (&renderer.slots) |*slot| slot.visible = false;
        renderer.visible_count = 0;
        renderer.render_deferred = false;
        renderer.frame_usable = renderer.supported and renderer.text != null and
            (icon_theme != .nerd_font or renderer.icons != null) and
            renderer.cell_width != 0 and renderer.cell_height != 0 and
            !area.isEmpty();
        const colors = resolveColors(palette) orelse {
            renderer.frame_usable = false;
            renderer.retireInvisible();
            return;
        };
        if (!renderer.frame_usable) {
            renderer.retireInvisible();
            return;
        }

        const count = @min(
            @as(usize, center.count),
            @as(usize, (area.h + toast.card_gap) / (toast.card_height + toast.card_gap)),
        );
        renderer.visible_count = @intCast(count);
        // Release the one id that the bounded center may have evicted before
        // assigning a slot to the new front item. Existing ids retain their
        // stable host image ids even though their vertical order changed.
        for (&renderer.slots) |*slot| {
            if (slot.id == .invalid) continue;
            var retained = false;
            for (0..count) |index| {
                if (center.itemAt(index).?.id == slot.id) {
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
            const item = center.itemAt(index).?;
            const slot = renderer.slotFor(item.id) orelse {
                renderer.frame_usable = false;
                break;
            };
            slot.visible = true;
            const key: RenderKey = .{
                .id = item.id,
                .level = item.level,
                .cell_width = renderer.cell_width,
                .cell_height = renderer.cell_height,
                .card_columns = area.w,
                .icon_theme = icon_theme,
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
                renderer.renderSlot(slot, item, key) catch {
                    slot.key = null;
                    slot.failed_key = key;
                    renderer.frame_usable = false;
                    continue;
                };
            }
            const full_width = slot.width;
            const visible_width = item.animatedPixels(full_width);
            const right = (@as(u32, area.x) + area.w) * renderer.cell_width;
            const pixel_x = right -| visible_width;
            const pixel_y = (@as(u32, area.y) + @as(u32, @intCast(index)) *
                (toast.card_height + toast.card_gap)) * renderer.cell_height;
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
        if (!renderer.frame_usable or renderer.visible_count == 0) return false;
        var count: u8 = 0;
        for (&renderer.slots) |*slot| {
            if (!slot.visible) continue;
            count += 1;
            if (!slot.image_emitted or slot.image_dirty) return false;
            if (slot.placement != null and slot.emitted_placement == null) return false;
        }
        return count == renderer.visible_count;
    }

    /// The notification center may change before the lower-priority media
    /// pass catches up. Never hide the cell fallback for a stale texture set.
    pub fn covers(renderer: *const Renderer, center: *const notifications.Center) bool {
        if (!renderer.coversAll() or renderer.visible_count != center.count) return false;
        for (0..center.count) |index| {
            const id = center.itemAt(index).?.id;
            for (renderer.slots) |slot| {
                if (slot.id == id and slot.visible and slot.image_emitted and
                    !slot.image_dirty) break;
            } else return false;
        }
        return true;
    }

    pub fn damaged(renderer: *const Renderer) bool {
        if (renderer.render_deferred) return true;
        if (renderer.transmissionPending()) return true;
        const placements_enabled = renderer.allImagesReady();
        for (&renderer.slots) |*slot| {
            if (slot.transfer_offset != 0) return true;
            if (!renderer.frame_usable and slot.image_emitted) return true;
            const desired = if (placements_enabled and slot.visible) slot.placement else null;
            if (!optionalPlacementEql(desired, slot.emitted_placement)) return true;
            if (!slot.visible and slot.image_emitted) return true;
        }
        return false;
    }

    pub fn transmissionPending(renderer: *const Renderer) bool {
        if (!renderer.frame_usable) return false;
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
        if (!renderer.render_deferred) return false;
        const placements_enabled = renderer.allImagesReady();
        for (renderer.slots) |slot| {
            if (slot.transfer_offset != 0) return false;
            if ((!slot.visible or slot.image_dirty or !renderer.frame_usable) and
                slot.image_emitted) return false;
            const desired = if (placements_enabled and slot.visible) slot.placement else null;
            if (!optionalPlacementEql(desired, slot.emitted_placement)) return false;
        }
        return true;
    }

    /// Deletions and placements are always cheap enough to emit. A new image
    /// is sent only when the pane-media writer used no budget in this pass.
    pub fn write(
        renderer: *Renderer,
        writer: *std.Io.Writer,
        allow_transmission: bool,
    ) std.Io.Writer.Error!usize {
        var written: usize = 0;
        for (&renderer.slots, 0..) |*slot, index| {
            const transfer_stale = slot.transfer_offset != 0 and
                (!slot.visible or !renderer.frame_usable or slot.key == null or
                    slot.transfer_key == null or
                    !std.meta.eql(slot.transfer_key.?, slot.key.?));
            if (transfer_stale) {
                written += try kitty.writeTransmissionAbort(writer);
                slot.transfer_offset = 0;
                slot.transfer_key = null;
            }
            if ((!slot.visible or slot.image_dirty or !renderer.frame_usable) and
                slot.image_emitted)
            {
                written += try kitty.writeDeleteImage(writer, imageId(index));
                slot.image_emitted = false;
                slot.emitted_placement = null;
                if (renderer.render_deferred and slot.visible and slot.key != null)
                    slot.image_dirty = true;
            }
        }

        if ((allow_transmission or renderer.transferInProgress()) and
            renderer.frame_usable)
        transmit: {
            for (&renderer.slots, 0..) |*slot, index| {
                if (!slot.visible or !slot.image_dirty or slot.key == null) continue;
                if (slot.transfer_offset == 0) slot.transfer_key = slot.key;
                const progress = try kitty.writeTransmissionChunks(writer, imageId(index), .{
                    .key = .{ .image_id = imageId(index), .generation = 1 },
                    .format = .rgba,
                    .width = slot.width,
                    .height = slot.height,
                    .byte_len = slot.pixels.len,
                }, slot.pixels, slot.transfer_offset, kitty.transmission_budget_per_frame, false);
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
            if (optionalPlacementEql(desired, slot.emitted_placement)) continue;
            if (slot.emitted_placement != null) written += try kitty.writeDeletePlacement(
                writer,
                imageId(index),
                placementId(index),
            );
            if (desired) |placement| {
                written += try kitty.writePlacement(
                    writer,
                    imageId(index),
                    placementId(index),
                    placement,
                    toast_z_index,
                );
            }
            slot.emitted_placement = desired;
        }
        return written;
    }

    fn slotFor(renderer: *Renderer, id: notifications.Id) ?*Slot {
        for (&renderer.slots) |*slot| if (slot.id == id) return slot;
        for (&renderer.slots) |*slot| {
            if (slot.visible or slot.id != .invalid) continue;
            slot.id = id;
            return slot;
        }
        for (&renderer.slots) |*slot| {
            if (slot.visible) continue;
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
            if (slot.visible) continue;
            slot.id = .invalid;
            slot.key = null;
            slot.failed_key = null;
            slot.placement = null;
            slot.image_dirty = false;
        }
    }

    fn renderSlot(
        renderer: *Renderer,
        slot: *Slot,
        item: *const notifications.Item,
        key: RenderKey,
    ) !void {
        const width = std.math.mul(u32, key.card_columns, renderer.cell_width) catch
            return error.ToastTooLarge;
        const height = std.math.mul(u32, toast.card_height, renderer.cell_height) catch
            return error.ToastTooLarge;
        const pixel_count = std.math.mul(usize, width, height) catch
            return error.ToastTooLarge;
        const byte_count = std.math.mul(usize, pixel_count, 4) catch
            return error.ToastTooLarge;
        if (byte_count > max_image_bytes) return error.ToastTooLarge;
        if (slot.pixels.len != byte_count) {
            if (slot.pixels.len == 0)
                slot.pixels = try renderer.gpa.alloc(u8, byte_count)
            else
                slot.pixels = try renderer.gpa.realloc(slot.pixels, byte_count);
        }
        slot.width = width;
        slot.height = height;
        const surface: raster.Surface = .{
            .pixels = slot.pixels,
            .width = width,
            .height = height,
        };
        fill(surface, .{ key.background[0], key.background[1], key.background[2], 255 });
        const accent = rasterColor(key.accent);
        const border = @min(
            @max(@as(u32, 1), renderer.cell_width / 8),
            @max(@as(u32, 1), @min(width, height) / 2),
        );
        fillRect(surface, 0, 0, width, border, accent);
        fillRect(surface, 0, height - border, width, border, accent);
        fillRect(surface, 0, 0, border, height, accent);
        fillRect(surface, width - border, 0, border, height, accent);
        fillRect(surface, border, border, @max(border, renderer.cell_width / 3), height - border * 2, accent);

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
        _ = try text.drawText(
            surface,
            left,
            baseline(metrics, 0, renderer.cell_height),
            item.title(),
            accent,
            max_text_width,
        );
        _ = try text.drawText(
            surface,
            left,
            baseline(metrics, renderer.cell_height, renderer.cell_height),
            item.message(),
            rasterColor(key.text),
            width -| @as(u32, @intCast(left)) -| @as(u32, renderer.cell_width) * 2,
        );
        const hint = if (item.clickable()) "click to open" else "click to dismiss";
        _ = try text.drawText(
            surface,
            left,
            baseline(metrics, @as(u32, renderer.cell_height) * 2, renderer.cell_height),
            hint,
            rasterColor(key.subtext),
            width -| @as(u32, @intCast(left)) -| @as(u32, renderer.cell_width) * 2,
        );
        const close_x: i32 = @intCast(width -| @as(u32, renderer.cell_width) * 3);
        if (key.icon_theme == .nerd_font) {
            const icons = &renderer.icons.?;
            try icons.setPixelHeight(font_height);
            _ = try icons.drawText(
                surface,
                close_x,
                baseline(icons.metrics(), 0, renderer.cell_height),
                ui_icons.Icon.close.nerdGlyph(),
                accent,
                @as(u32, renderer.cell_width) * 2,
            );
        } else {
            _ = try text.drawText(
                surface,
                close_x,
                baseline(metrics, 0, renderer.cell_height),
                ui_icons.Icon.close.unicodeGlyph(),
                accent,
                @as(u32, renderer.cell_width) * 2,
            );
        }
        slot.key = key;
        slot.failed_key = null;
        slot.image_dirty = true;
    }

    fn allImagesReady(renderer: *const Renderer) bool {
        if (!renderer.frame_usable or renderer.visible_count == 0) return false;
        var count: u8 = 0;
        for (&renderer.slots) |slot| {
            if (!slot.visible) continue;
            count += 1;
            if (slot.key == null or slot.image_dirty or !slot.image_emitted) return false;
        }
        return count == renderer.visible_count;
    }
};

const Colors = struct {
    surface0: [3]u8,
    text: [3]u8,
    subtext: [3]u8,
    blue: [3]u8,
    green: [3]u8,
    yellow: [3]u8,
    red: [3]u8,

    fn level(colors: Colors, value: notifications.Level) [3]u8 {
        return switch (value) {
            .info => colors.blue,
            .success => colors.green,
            .warning => colors.yellow,
            .failure => colors.red,
        };
    }
};

fn resolveColors(palette: *const theme.Palette) ?Colors {
    return .{
        .surface0 = rgb(palette.surface0) orelse return null,
        .text = rgb(palette.text) orelse return null,
        .subtext = rgb(palette.subtext0) orelse return null,
        .blue = rgb(palette.blue) orelse return null,
        .green = rgb(palette.green) orelse return null,
        .yellow = rgb(palette.yellow) orelse return null,
        .red = rgb(palette.red) orelse return null,
    };
}

fn rgb(color: ui.Color) ?[3]u8 {
    return switch (color) {
        .rgb => |value| value,
        else => null,
    };
}

fn rasterColor(value: [3]u8) raster.Color {
    return .{ .red = value[0], .green = value[1], .blue = value[2] };
}

fn baseline(metrics: raster.Metrics, row_y: u32, row_height: u16) i32 {
    const spare = @as(i32, row_height) - @as(i32, @intCast(metrics.line_height));
    const centered_y: i32 = @intCast(row_y + @as(u32, @intCast(@max(0, @divTrunc(spare, 2)))));
    return centered_y + metrics.ascender;
}

fn fill(surface: raster.Surface, color: [4]u8) void {
    var index: usize = 0;
    while (index < surface.pixels.len) : (index += 4)
        @memcpy(surface.pixels[index..][0..4], &color);
}

fn fillRect(
    surface: raster.Surface,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    color: raster.Color,
) void {
    const right = @min(surface.width, x +| width);
    const bottom = @min(surface.height, y +| height);
    var row = y;
    while (row < bottom) : (row += 1) {
        var column = x;
        while (column < right) : (column += 1) {
            const index = (@as(usize, row) * surface.width + column) * 4;
            surface.pixels[index..][0..4].* = .{ color.red, color.green, color.blue, color.alpha };
        }
    }
}

fn imageId(index: usize) u32 {
    return first_image_id + @as(u32, @intCast(index));
}

fn placementId(index: usize) u32 {
    return first_placement_id + @as(u32, @intCast(index));
}

fn optionalPlacementEql(a: ?kitty.OutputPlacement, b: ?kitty.OutputPlacement) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.meta.eql(a.?, b.?);
}

test "terminal-derived palettes keep the cell fallback" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    _ = renderer.configure(.supported, 10, 20);
    var center: notifications.Center = .{};
    _ = center.push(0, .{ .title = "Ready", .message = "Open result" });
    renderer.prepare(.{ .w = 48, .h = 4 }, &center, &theme.builtin(.terminal).palette);
    try std.testing.expect(!renderer.frame_usable);
    try std.testing.expect(!renderer.coversAll());
}

test "Nerd Font theme rasterizes the close icon into graphical toasts" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    try std.testing.expect(renderer.icons != null);
    _ = renderer.configure(.supported, 10, 20);
    renderer.setMediaIdle(true);
    var center: notifications.Center = .{};
    _ = center.push(0, .{ .title = "Ready", .message = "Open result" });
    _ = center.advance(notifications.transition_duration_ns);
    renderer.prepareThemed(
        .{ .w = 48, .h = 4 },
        &center,
        &theme.default_theme.palette,
        .nerd_font,
    );
    try std.testing.expect(renderer.frame_usable);
    try std.testing.expectEqual(ui_icons.Theme.nerd_font, renderer.slots[0].key.?.icon_theme);
}

test "toast pixel cache is bounded independently of wire pacing" {
    try std.testing.expectEqual(@as(usize, 1536 * 1024), max_image_bytes);
}

test "large toast transmission is chunked across bounded media passes" {
    const Io = std.Io;
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    // These are the cell dimensions from the instrumented Ghostty session:
    // one 48x4-cell toast is 1,056x232 pixels, or 979,968 retained RGBA bytes.
    _ = renderer.configure(.supported, 22, 58);
    renderer.setMediaIdle(true);
    var center: notifications.Center = .{};
    const id = center.push(0, .{
        .level = .success,
        .title = "Build complete",
        .message = "Open the result",
        .target = .{ .select_tab = @enumFromInt(7) },
    });
    _ = center.advance(notifications.transition_duration_ns);
    const area: ui.Rect = .{ .x = 20, .y = 1, .w = 48, .h = 4 };
    renderer.prepare(area, &center, &theme.default_theme.palette);
    try std.testing.expect(renderer.transmissionPending());
    try std.testing.expect(!renderer.coversAll());

    var first: Io.Writer.Allocating = .init(std.testing.allocator);
    defer first.deinit();
    _ = try renderer.write(&first.writer, true);
    try std.testing.expect(std.mem.indexOf(u8, first.written(), "a=t") != null);
    try std.testing.expect(first.written().len <= kitty.transmission_budget_per_frame + 8192);
    try std.testing.expect(renderer.transmissionPending());
    var placed = std.mem.indexOf(u8, first.written(), "a=p") != null;
    var passes: usize = 1;
    while (renderer.transmissionPending()) {
        passes += 1;
        var chunk: Io.Writer.Allocating = .init(std.testing.allocator);
        defer chunk.deinit();
        // Once the first m=1 chunk is on the wire, the transfer must close
        // even if fresh host input disables starting another texture.
        _ = try renderer.write(&chunk.writer, false);
        try std.testing.expect(chunk.written().len <= kitty.transmission_budget_per_frame + 8192);
        placed = placed or std.mem.indexOf(u8, chunk.written(), "a=p") != null;
    }
    try std.testing.expect(passes > 1);
    try std.testing.expect(renderer.coversAll());
    try std.testing.expect(placed);

    _ = center.dismiss(id, notifications.transition_duration_ns);
    _ = center.advance(notifications.transition_duration_ns + notifications.transition_duration_ns / 2);
    renderer.prepare(area, &center, &theme.default_theme.palette);
    var moving: Io.Writer.Allocating = .init(std.testing.allocator);
    defer moving.deinit();
    _ = try renderer.write(&moving.writer, true);
    try std.testing.expect(std.mem.indexOf(u8, moving.written(), "a=t") == null);
    try std.testing.expect(std.mem.indexOf(u8, moving.written(), "a=p") != null);

    _ = center.advance(notifications.transition_duration_ns * 2);
    renderer.prepare(area, &center, &theme.default_theme.palette);
    var removed: Io.Writer.Allocating = .init(std.testing.allocator);
    defer removed.deinit();
    _ = try renderer.write(&removed.writer, true);
    try std.testing.expect(std.mem.indexOf(u8, removed.written(), "a=d,d=I") != null);
}

test "rasterization waits for media idle and oversized cells fall back" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    _ = renderer.configure(.supported, 10, 20);
    var center: notifications.Center = .{};
    _ = center.push(0, .{ .title = "Ready", .message = "Open result" });
    _ = center.advance(notifications.transition_duration_ns);
    const area: ui.Rect = .{ .w = 48, .h = 4 };

    renderer.setMediaIdle(false);
    renderer.prepare(area, &center, &theme.default_theme.palette);
    try std.testing.expect(renderer.render_deferred);
    try std.testing.expect(renderer.damaged());
    try std.testing.expect(!renderer.transmissionPending());

    renderer.setMediaIdle(true);
    renderer.prepare(area, &center, &theme.default_theme.palette);
    try std.testing.expect(renderer.transmissionPending());

    _ = renderer.configure(.supported, 40, 80);
    renderer.prepare(area, &center, &theme.default_theme.palette);
    try std.testing.expect(!renderer.frame_usable);
    try std.testing.expect(!renderer.coversAll());
}
