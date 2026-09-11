const Renderer = @This();
const std = @import("std");
const raster = @import("rasterizer_support.zig");
const ui_icons = @import("../ui/root.zig").icons;
const Slot = @import("IconsSlot.zig");
const Placement = @import("Placement.zig");
const source_namespace = @import("icons.zig");
const kitty = @import("kitty.zig");
gpa: std.mem.Allocator,
text: ?raster.Rasterizer,
supported: bool = false,
failed: bool = false,
cell_width: u16 = 0,
cell_height: u16 = 0,
pixel_width: u16 = 0,
pixel_height: u16 = 0,
atlas: []u8 = &.{},
atlas_width: u32 = 0,
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
        .text = raster.Rasterizer.initFont(source_namespace.embedded_font) catch null,
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

/// Applies host graphics support and cell geometry to the icon atlas.
/// For example: `_ = renderer.configure(.{ .support = .supported, .cell_width = 10, .cell_height = 20 });`.
pub fn configure(renderer: *Renderer, configuration: kitty.Configuration) bool {
    const supported = configuration.support == .supported and renderer.text != null;
    if (renderer.supported == supported and renderer.cell_width == configuration.cell_width and
        renderer.cell_height == configuration.cell_height)
    {
        return false;
    }
    renderer.supported = supported;
    renderer.cell_width = configuration.cell_width;
    renderer.cell_height = configuration.cell_height;
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
        const wanted = source_namespace.slotFromMark(mark);
        if (source_namespace.isWorkingIcon(mark.icon)) {
            inline for (.{
                ui_icons.Icon.agent_working_0,
                ui_icons.Icon.agent_working_1,
                ui_icons.Icon.agent_working_2,
                ui_icons.Icon.agent_working_3,
            }) |frame| {
                _ = try source_namespace.ensureSlot(&next_slots, &next_slot_count, .{
                    .icon = frame,
                    .foreground = mark.foreground,
                    .background = mark.background,
                    .columns = wanted.columns,
                });
            }
        }
        const slot = try source_namespace.ensureSlot(&next_slots, &next_slot_count, wanted);
        next_placements[mark_index] = .{ .area = mark.area, .slot = slot };
    }
    const next_placement_count: u8 = @intCast(marks.len);
    const raster_size = source_namespace.fitCell(renderer.cell_width, renderer.cell_height);
    const atlas_width = @as(u32, raster_size.width) * source_namespace.widestSlot(next_slots[0..next_slot_count]);
    const slots_changed = renderer.pixel_width != raster_size.width or
        renderer.pixel_height != raster_size.height or
        renderer.atlas_width != atlas_width or
        !source_namespace.slotsEqual(
            renderer.slots[0..renderer.slot_count],
            next_slots[0..next_slot_count],
        );

    if (slots_changed) {
        const atlas_height = std.math.mul(u32, raster_size.height, next_slot_count) catch
            return error.IconAtlasTooLarge;
        const atlas_len = try source_namespace.rgbaLength(atlas_width, atlas_height);
        if (atlas_len > source_namespace.max_atlas_bytes) {
            return error.IconAtlasTooLarge;
        }
        const next_atlas = try renderer.gpa.alloc(u8, atlas_len);
        errdefer renderer.gpa.free(next_atlas);
        const text = if (renderer.text) |*value| value else unreachable;
        try source_namespace.renderAtlas(text, .{
            .pixels = next_atlas,
            .raster_size = raster_size,
            .atlas_width = atlas_width,
            .slots = next_slots[0..next_slot_count],
        });
        if (renderer.atlas.len != 0) {
            renderer.gpa.free(renderer.atlas);
        }
        renderer.atlas = next_atlas;
        renderer.atlas_width = atlas_width;
        renderer.atlas_height = atlas_height;
        renderer.pixel_width = raster_size.width;
        renderer.pixel_height = raster_size.height;
        @memcpy(renderer.slots[0..next_slot_count], next_slots[0..next_slot_count]);
        renderer.slot_count = next_slot_count;
        renderer.transfer_abort_pending = renderer.transfer_offset != 0;
        renderer.image_dirty = true;
        renderer.placements_dirty = true;
    }

    if (!source_namespace.placementsEqual(
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

pub fn write(renderer: *Renderer, writer: *source_namespace.Io.Writer) source_namespace.Io.Writer.Error!usize {
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
            written += try kitty.writeDeleteImage(writer, source_namespace.image_id);
        }
        renderer.image_emitted = false;
        renderer.image_dirty = false;
        renderer.placements_dirty = false;
        renderer.emitted_placement_count = 0;
        return written;
    }

    if (renderer.image_dirty) {
        if (renderer.transfer_offset == 0 and renderer.image_emitted) {
            written += try kitty.writeDeleteImage(writer, source_namespace.image_id);
            renderer.image_emitted = false;
            renderer.emitted_placement_count = 0;
        }
        const progress = try kitty.writeTransmissionChunks(writer, .{
            .external_id = source_namespace.image_id,
            .image = .{
                .key = .{ .image_id = source_namespace.image_id, .generation = 1 },
                .format = .rgba,
                .width = renderer.atlas_width,
                .height = renderer.atlas_height,
                .byte_len = renderer.atlas.len,
            },
            .pixels = renderer.atlas,
            .start_offset = renderer.transfer_offset,
            .budget = kitty.transmission_budget_per_frame,
            .compressed = false,
        });
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
                source_namespace.image_id,
                source_namespace.first_placement_id + @as(u32, @intCast(index)),
            );
        }
        for (renderer.placements[0..renderer.placement_count], 0..) |placement, index| {
            const columns: u32 = renderer.slots[placement.slot].columns;
            written += try kitty.writePlacement(writer, .{
                .image_id = source_namespace.image_id,
                .placement_id = source_namespace.first_placement_id + @as(u32, @intCast(index)),
                .value = .{
                    .column = placement.area.x,
                    .row = placement.area.y,
                    .offset_x = 0,
                    .offset_y = 0,
                    .source_x = 0,
                    .source_y = @as(u32, placement.slot) * renderer.pixel_height,
                    .source_width = columns * renderer.pixel_width,
                    .source_height = renderer.pixel_height,
                    .columns = columns,
                    .rows = 1,
                },
                .z = source_namespace.z_index,
            });
        }
        renderer.emitted_placement_count = renderer.placement_count;
        renderer.placements_dirty = false;
    }
    return written;
}
