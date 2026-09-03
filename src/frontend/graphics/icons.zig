//! Embedded Nerd Font icon rasterization and KGP placement.
//!
//! The widget frame supplies a bounded list of semantic marks. Preparation
//! deduplicates their glyph/color tuples and builds one opaque atlas outside
//! the interactive path. Cell fallbacks remain underneath every placement.

const std = @import("std");
const core = @import("telar-core");
const kitty = @import("kitty.zig");
const raster = @import("rasterizer.zig");
const ui_icons = @import("../ui/root.zig").icons;

const Io = std.Io;

pub const embedded_font: []const u8 = @embedFile("../assets/TelarNerdIcons-Regular.ttf");

const image_id: u32 = 0x80000004;
const first_placement_id: u32 = 0x80000200;
const z_index: i32 = 10;
const max_pixel_dimension: u16 = 48;
pub const max_atlas_bytes: usize = 1536 * 1024;

const Slot = struct {
    icon: ui_icons.Icon,
    foreground: [3]u8,
    background: [3]u8,
};

const Placement = struct {
    area: core.ui.Rect,
    slot: u8,
};

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    text: ?raster.Rasterizer,
    supported: bool = false,
    failed: bool = false,
    cell_width: u16 = 0,
    cell_height: u16 = 0,
    pixel_width: u16 = 0,
    pixel_height: u16 = 0,
    atlas: []u8 = &.{},
    atlas_height: u32 = 0,
    slots: [ui_icons.max_marks]Slot = undefined,
    slot_count: u8 = 0,
    placements: [ui_icons.max_marks]Placement = undefined,
    placement_count: u8 = 0,
    emitted_placement_count: u8 = 0,
    visible: bool = false,
    image_emitted: bool = false,
    image_dirty: bool = false,
    placements_dirty: bool = false,
    transfer_offset: usize = 0,
    transfer_abort_pending: bool = false,

    pub fn init(gpa: std.mem.Allocator) Renderer {
        return .{
            .gpa = gpa,
            .text = raster.Rasterizer.initFont(embedded_font) catch null,
        };
    }

    pub fn deinit(renderer: *Renderer) void {
        if (renderer.atlas.len != 0) {
            renderer.gpa.free(renderer.atlas);
        }
        if (renderer.text) |*text| {
            text.deinit();
        }
    }

    pub fn retainedBytes(renderer: *const Renderer) usize {
        return renderer.atlas.len;
    }

    pub fn available(renderer: *const Renderer) bool {
        return renderer.supported and !renderer.failed;
    }

    pub fn configure(renderer: *Renderer, support: kitty.Support, cell_width: u16, cell_height: u16) bool {
        const supported = support == .supported and renderer.text != null;
        if (renderer.supported == supported and renderer.cell_width == cell_width and
            renderer.cell_height == cell_height)
        {
            return false;
        }
        renderer.supported = supported;
        renderer.cell_width = cell_width;
        renderer.cell_height = cell_height;
        renderer.failed = false;
        return true;
    }

    pub fn disable(renderer: *Renderer) void {
        renderer.failed = true;
        renderer.visible = false;
        renderer.placement_count = 0;
        renderer.placements_dirty = renderer.image_emitted or renderer.transfer_offset != 0;
    }

    pub fn prepare(renderer: *Renderer, marks: []const ui_icons.Mark) !void {
        if (marks.len > ui_icons.max_marks) {
            return error.TooManyIconMarks;
        }
        if (!renderer.supported or renderer.failed or renderer.cell_width == 0 or
            renderer.cell_height == 0 or marks.len == 0)
        {
            renderer.visible = false;
            renderer.placement_count = 0;
            renderer.placements_dirty = renderer.image_emitted or renderer.transfer_offset != 0;
            return;
        }

        var next_slots: [ui_icons.max_marks]Slot = undefined;
        var next_slot_count: u8 = 0;
        var next_placements: [ui_icons.max_marks]Placement = undefined;
        for (marks, 0..) |mark, mark_index| {
            const wanted = slotFromMark(mark);
            if (isWorkingIcon(mark.icon)) {
                inline for (.{
                    ui_icons.Icon.agent_working_0,
                    ui_icons.Icon.agent_working_1,
                    ui_icons.Icon.agent_working_2,
                    ui_icons.Icon.agent_working_3,
                }) |frame| {
                    _ = try ensureSlot(&next_slots, &next_slot_count, .{
                        .icon = frame,
                        .foreground = mark.foreground,
                        .background = mark.background,
                    });
                }
            }
            const slot = try ensureSlot(&next_slots, &next_slot_count, wanted);
            next_placements[mark_index] = .{ .area = mark.area, .slot = slot };
        }
        const next_placement_count: u8 = @intCast(marks.len);
        const raster_size = fitCell(renderer.cell_width, renderer.cell_height);
        const slots_changed = renderer.pixel_width != raster_size.width or
            renderer.pixel_height != raster_size.height or
            !slotsEqual(
                renderer.slots[0..renderer.slot_count],
                next_slots[0..next_slot_count],
            );

        if (slots_changed) {
            const atlas_height = std.math.mul(u32, raster_size.height, next_slot_count) catch
                return error.IconAtlasTooLarge;
            const atlas_len = try rgbaLength(raster_size.width, atlas_height);
            if (atlas_len > max_atlas_bytes) {
                return error.IconAtlasTooLarge;
            }
            const next_atlas = try renderer.gpa.alloc(u8, atlas_len);
            errdefer renderer.gpa.free(next_atlas);
            const text = if (renderer.text) |*value| value else unreachable;
            try renderAtlas(
                text,
                next_atlas,
                raster_size,
                next_slots[0..next_slot_count],
            );
            if (renderer.atlas.len != 0) {
                renderer.gpa.free(renderer.atlas);
            }
            renderer.atlas = next_atlas;
            renderer.atlas_height = atlas_height;
            renderer.pixel_width = raster_size.width;
            renderer.pixel_height = raster_size.height;
            @memcpy(renderer.slots[0..next_slot_count], next_slots[0..next_slot_count]);
            renderer.slot_count = next_slot_count;
            renderer.transfer_abort_pending = renderer.transfer_offset != 0;
            renderer.image_dirty = true;
            renderer.placements_dirty = true;
        }

        if (!placementsEqual(
            renderer.placements[0..renderer.placement_count],
            next_placements[0..next_placement_count],
        )) {
            @memcpy(
                renderer.placements[0..next_placement_count],
                next_placements[0..next_placement_count],
            );
            renderer.placement_count = next_placement_count;
            renderer.placements_dirty = true;
        }
        if (!renderer.visible) {
            renderer.placements_dirty = true;
        }
        renderer.visible = true;
    }

    pub fn damaged(renderer: *const Renderer) bool {
        return renderer.transfer_abort_pending or renderer.transfer_offset != 0 or
            renderer.image_dirty or renderer.placements_dirty;
    }

    pub fn transferInProgress(renderer: *const Renderer) bool {
        return renderer.transfer_offset != 0;
    }

    pub fn write(renderer: *Renderer, writer: *Io.Writer) Io.Writer.Error!usize {
        if (!renderer.damaged()) {
            return 0;
        }
        var written: usize = 0;
        if (renderer.transfer_abort_pending) {
            written += try kitty.writeTransmissionAbort(writer);
            renderer.transfer_abort_pending = false;
            renderer.transfer_offset = 0;
        }

        if (!renderer.visible) {
            if (renderer.transfer_offset != 0) {
                written += try kitty.writeTransmissionAbort(writer);
                renderer.transfer_offset = 0;
            }
            if (renderer.image_emitted) {
                written += try kitty.writeDeleteImage(writer, image_id);
            }
            renderer.image_emitted = false;
            renderer.image_dirty = false;
            renderer.placements_dirty = false;
            renderer.emitted_placement_count = 0;
            return written;
        }

        if (renderer.image_dirty) {
            if (renderer.transfer_offset == 0 and renderer.image_emitted) {
                written += try kitty.writeDeleteImage(writer, image_id);
                renderer.image_emitted = false;
                renderer.emitted_placement_count = 0;
            }
            const progress = try kitty.writeTransmissionChunks(
                writer,
                image_id,
                .{
                    .key = .{ .image_id = image_id, .generation = 1 },
                    .format = .rgba,
                    .width = renderer.pixel_width,
                    .height = renderer.atlas_height,
                    .byte_len = renderer.atlas.len,
                },
                renderer.atlas,
                renderer.transfer_offset,
                kitty.transmission_budget_per_frame,
                false,
            );
            written += progress.written;
            renderer.transfer_offset = progress.offset;
            if (progress.offset != renderer.atlas.len) {
                return written;
            }
            renderer.transfer_offset = 0;
            renderer.image_dirty = false;
            renderer.image_emitted = true;
        }

        if (renderer.placements_dirty and renderer.image_emitted) {
            for (0..renderer.emitted_placement_count) |index| {
                written += try kitty.writeDeletePlacement(
                    writer,
                    image_id,
                    first_placement_id + @as(u32, @intCast(index)),
                );
            }
            for (renderer.placements[0..renderer.placement_count], 0..) |placement, index| {
                written += try kitty.writePlacement(
                    writer,
                    image_id,
                    first_placement_id + @as(u32, @intCast(index)),
                    .{
                        .column = placement.area.x,
                        .row = placement.area.y,
                        .offset_x = 0,
                        .offset_y = 0,
                        .source_x = 0,
                        .source_y = @as(u32, placement.slot) * renderer.pixel_height,
                        .source_width = renderer.pixel_width,
                        .source_height = renderer.pixel_height,
                        .columns = 1,
                        .rows = 1,
                    },
                    z_index,
                );
            }
            renderer.emitted_placement_count = renderer.placement_count;
            renderer.placements_dirty = false;
        }
        return written;
    }
};

fn slotFromMark(mark: ui_icons.Mark) Slot {
    return .{
        .icon = mark.icon,
        .foreground = mark.foreground,
        .background = mark.background,
    };
}

fn ensureSlot(slots: *[ui_icons.max_marks]Slot, count: *u8, wanted: Slot) !u8 {
    if (findSlot(slots[0..count.*], wanted)) |slot| {
        return slot;
    }
    if (count.* == slots.len) {
        return error.TooManyIconSlots;
    }
    slots[count.*] = wanted;
    const added = count.*;
    count.* += 1;
    return added;
}

fn isWorkingIcon(icon: ui_icons.Icon) bool {
    return switch (icon) {
        .agent_working_0,
        .agent_working_1,
        .agent_working_2,
        .agent_working_3,
        => true,
        else => false,
    };
}

fn findSlot(slots: []const Slot, wanted: Slot) ?u8 {
    for (slots, 0..) |slot, index| {
        if (std.meta.eql(slot, wanted)) {
            return @intCast(index);
        }
    }
    return null;
}

fn slotsEqual(a: []const Slot, b: []const Slot) bool {
    if (a.len != b.len) {
        return false;
    }
    for (a, b) |left, right| if (!std.meta.eql(left, right)) return false;
    return true;
}

fn placementsEqual(a: []const Placement, b: []const Placement) bool {
    if (a.len != b.len) {
        return false;
    }
    for (a, b) |left, right| if (!std.meta.eql(left, right)) return false;
    return true;
}

fn rgbaLength(width: u32, height: u32) !usize {
    const pixels = std.math.mul(usize, width, height) catch
        return error.IconAtlasTooLarge;
    return std.math.mul(usize, pixels, 4) catch error.IconAtlasTooLarge;
}

const RasterSize = struct {
    width: u16,
    height: u16,
};

fn fitCell(cell_width: u16, cell_height: u16) RasterSize {
    const longest = @max(cell_width, cell_height);
    if (longest <= max_pixel_dimension) {
        return .{
            .width = cell_width,
            .height = cell_height,
        };
    }
    return .{
        .width = scaledDimension(cell_width, longest),
        .height = scaledDimension(cell_height, longest),
    };
}

fn scaledDimension(value: u16, longest: u16) u16 {
    const numerator = @as(u32, value) * max_pixel_dimension + longest / 2;
    return @intCast(@max(1, numerator / longest));
}

fn renderAtlas(text: *raster.Rasterizer, pixels: []u8, raster_size: RasterSize, slots: []const Slot) !void {
    const icon_size = @min(raster_size.width, raster_size.height);
    try text.setPixelHeight(icon_size);
    const metrics = text.metrics();
    const line_top = @divTrunc(
        @as(i32, raster_size.height) - @as(i32, @intCast(metrics.line_height)),
        2,
    );
    const baseline = line_top + metrics.ascender;
    const slot_bytes = @as(usize, raster_size.width) * raster_size.height * 4;
    for (slots, 0..) |slot, index| {
        const surface: raster.Surface = .{
            .pixels = pixels[index * slot_bytes ..][0..slot_bytes],
            .width = raster_size.width,
            .height = raster_size.height,
        };
        fill(surface, slot.background);
        const advance = try text.drawText(
            surface,
            0,
            baseline,
            slot.icon.nerdGlyph(),
            .{
                .red = slot.foreground[0],
                .green = slot.foreground[1],
                .blue = slot.foreground[2],
            },
            raster_size.width,
        );
        if (advance == 0) {
            return error.EmptyIconGlyph;
        }
    }
}

fn fill(surface: raster.Surface, color: [3]u8) void {
    var pixel: usize = 0;
    while (pixel < surface.pixels.len) : (pixel += 4) {
        surface.pixels[pixel] = color[0];
        surface.pixels[pixel + 1] = color[1];
        surface.pixels[pixel + 2] = color[2];
        surface.pixels[pixel + 3] = 255;
    }
}

test "embedded subset rasterizes every configured Nerd Font icon" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    try std.testing.expect(renderer.text != null);
    _ = renderer.configure(.supported, 10, 20);
    var marks: [std.meta.fields(ui_icons.Icon).len]ui_icons.Mark = undefined;
    inline for (std.meta.fields(ui_icons.Icon), 0..) |field, index| {
        marks[index] = .{
            .area = .{ .x = @intCast(index), .w = 1, .h = 1 },
            .icon = @enumFromInt(field.value),
            .foreground = .{ 255, 255, 255 },
            .background = .{ 20, 20, 20 },
        };
    }
    try renderer.prepare(&marks);
    try std.testing.expectEqual(marks.len, renderer.slot_count);
    try std.testing.expect(renderer.atlas.len <= max_atlas_bytes);
    const slot_bytes = @as(usize, renderer.pixel_width) * renderer.pixel_height * 4;
    for (0..renderer.slot_count) |index| {
        const pixels = renderer.atlas[index * slot_bytes ..][0..slot_bytes];
        var visible = false;
        var pixel: usize = 0;
        while (pixel < pixels.len) : (pixel += 4) {
            if (!std.mem.eql(u8, pixels[pixel..][0..3], &.{ 20, 20, 20 })) {
                visible = true;
                break;
            }
        }
        try std.testing.expect(visible);
    }
}

test "icon slots preserve the terminal cell aspect ratio" {
    try std.testing.expectEqual(RasterSize{ .width = 10, .height = 20 }, fitCell(10, 20));
    try std.testing.expectEqual(RasterSize{ .width = 24, .height = 48 }, fitCell(100, 200));
}

test "round Nerd Font icons remain square inside a tall cell" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    _ = renderer.configure(.supported, 20, 40);
    try renderer.prepare(&.{.{
        .area = .{ .w = 1, .h = 1 },
        .icon = .agent_ready,
        .foreground = .{ 255, 255, 255 },
        .background = .{ 20, 20, 20 },
    }});

    var min_x: u16 = renderer.pixel_width;
    var min_y: u16 = renderer.pixel_height;
    var max_x: u16 = 0;
    var max_y: u16 = 0;
    var found = false;
    for (0..renderer.pixel_height) |y| {
        for (0..renderer.pixel_width) |x| {
            const index = (@as(usize, y) * renderer.pixel_width + x) * 4;
            if (std.mem.eql(u8, renderer.atlas[index..][0..3], &.{ 20, 20, 20 })) {
                continue;
            }
            found = true;
            min_x = @min(min_x, @as(u16, @intCast(x)));
            min_y = @min(min_y, @as(u16, @intCast(y)));
            max_x = @max(max_x, @as(u16, @intCast(x)));
            max_y = @max(max_y, @as(u16, @intCast(y)));
        }
    }
    try std.testing.expect(found);
    const width = max_x - min_x + 1;
    const height = max_y - min_y + 1;
    try std.testing.expect(@abs(@as(i32, width) - @as(i32, height)) <= 2);
}

test "icon atlas is transmitted before its placements" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    _ = renderer.configure(.supported, 10, 20);
    try renderer.prepare(&.{.{
        .area = .{ .x = 2, .y = 3, .w = 1, .h = 1 },
        .icon = .cpu,
        .foreground = .{ 255, 255, 255 },
        .background = .{ 20, 20, 20 },
    }});

    var output: [16384]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    _ = try renderer.write(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "a=t") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "a=p") != null);
    try std.testing.expect(!renderer.damaged());
}

test "working animation changes placements without retransmitting the atlas" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    _ = renderer.configure(.supported, 10, 20);
    const style = ui_icons.Mark{
        .area = .{ .x = 2, .y = 3, .w = 1, .h = 1 },
        .icon = .agent_working_0,
        .foreground = .{ 255, 255, 255 },
        .background = .{ 20, 20, 20 },
    };
    try renderer.prepare(&.{style});
    var output: [65536]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    _ = try renderer.write(&writer);
    try std.testing.expect(!renderer.damaged());

    var next = style;
    next.icon = .agent_working_1;
    try renderer.prepare(&.{next});
    try std.testing.expect(!renderer.image_dirty);
    try std.testing.expect(renderer.placements_dirty);
}

test "unsupported terminals keep the renderer empty" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    _ = renderer.configure(.unsupported, 10, 20);
    try renderer.prepare(&.{.{
        .area = .{ .w = 1, .h = 1 },
        .icon = .cpu,
        .foreground = .{ 255, 255, 255 },
        .background = .{ 20, 20, 20 },
    }});
    try std.testing.expect(!renderer.damaged());
}
