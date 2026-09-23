const data = @import("model");
const SidebarRendererInput = @import("SidebarRendererInput.zig");
const client = @import("telar-client");
const kitty_protocol = @import("kitty_protocol");
const std = @import("std");
const Rasterizer = @import("Rasterizer.zig");
const ui_icons = @import("../ui/icons.zig");
const IconsSlot = @import("IconsSlot.zig");
const Placement = @import("Placement.zig");
const icons = @import("icons.zig");
const Mark = @import("../ui/Mark.zig");
const kitty_codec = @import("kitty_codec.zig");
const Renderer = @This();

gpa: std.mem.Allocator,
text: ?Rasterizer,
supported: bool = false,
failed: bool = false,
cell_width: u16 = 0,
cell_height: u16 = 0,
pixel_width: u16 = 0,
pixel_height: u16 = 0,
atlas: []u8 = &.{},
atlas_width: u32 = 0,
atlas_height: u32 = 0,
slots: [ui_icons.max_marks]IconsSlot = undefined,
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
        .text = Rasterizer.initFont(icons.embedded_font) catch null,
    };
}

pub fn deinit(self: *Renderer) void {
    if (self.atlas.len != 0) {
        self.gpa.free(self.atlas);
    }
    if (self.text) |*text| {
        text.deinit();
    }
}

pub fn retainedBytes(self: *const Renderer) usize {
    return self.atlas.len;
}

pub fn available(self: *const Renderer) bool {
    return self.supported and !self.failed;
}

/// Applies host graphics support and cell geometry to the icon atlas.
/// For example: `_ = renderer.configure(.{ .support = .supported, .cell_width = 10, .cell_height = 20 });`.
pub fn configure(self: *Renderer, configuration: SidebarRendererInput) bool {
    const supported = configuration.support == .supported and self.text != null;
    if (self.supported == supported and self.cell_width == configuration.cell_width and
        self.cell_height == configuration.cell_height)
    {
        return false;
    }
    self.supported = supported;
    self.cell_width = configuration.cell_width;
    self.cell_height = configuration.cell_height;
    self.failed = false;
    return true;
}

pub fn disable(self: *Renderer) void {
    self.failed = true;
    self.visible = false;
    self.placement_count = 0;
    self.placements_dirty = self.image_emitted or self.transfer_offset != 0;
}

pub fn prepare(self: *Renderer, marks: []const Mark) !void {
    if (marks.len > ui_icons.max_marks) {
        return error.TooManyIconMarks;
    }
    if (!self.supported or self.failed or self.cell_width == 0 or
        self.cell_height == 0 or marks.len == 0)
    {
        self.visible = false;
        self.placement_count = 0;
        self.placements_dirty = self.image_emitted or self.transfer_offset != 0;
        return;
    }

    var next_slots: [ui_icons.max_marks]IconsSlot = undefined;
    var next_slot_count: u8 = 0;
    var next_placements: [ui_icons.max_marks]Placement = undefined;
    for (marks, 0..) |mark, mark_index| {
        const wanted = icons.slotFromMark(mark);
        if (icons.isWorkingIcon(mark.icon)) {
            inline for (.{
                data.icons.Icon.agent_working_0,
                data.icons.Icon.agent_working_1,
                data.icons.Icon.agent_working_2,
                data.icons.Icon.agent_working_3,
            }) |frame| {
                _ = try icons.ensureSlot(&next_slots, &next_slot_count, .{
                    .icon = frame,
                    .foreground = mark.foreground,
                    .background = mark.background,
                    .columns = wanted.columns,
                });
            }
        }
        const slot = try icons.ensureSlot(&next_slots, &next_slot_count, wanted);
        next_placements[mark_index] = .{ .area = mark.area, .slot = slot };
    }
    const next_placement_count: u8 = @intCast(marks.len);
    const raster_size = icons.fitCell(self.cell_width, self.cell_height);
    const atlas_width = @as(u32, raster_size.width) * icons.widestSlot(next_slots[0..next_slot_count]);
    const slots_changed = self.pixel_width != raster_size.width or
        self.pixel_height != raster_size.height or
        self.atlas_width != atlas_width or
        !icons.slotsEqual(
            self.slots[0..self.slot_count],
            next_slots[0..next_slot_count],
        );

    if (slots_changed) {
        const atlas_height = std.math.mul(u32, raster_size.height, next_slot_count) catch
            return error.IconAtlasTooLarge;
        const atlas_len = try icons.rgbaLength(atlas_width, atlas_height);
        if (atlas_len > icons.max_atlas_bytes) {
            return error.IconAtlasTooLarge;
        }
        const next_atlas = try self.gpa.alloc(u8, atlas_len);
        errdefer self.gpa.free(next_atlas);
        const text = if (self.text) |*value| value else unreachable;
        try icons.renderAtlas(text, .{
            .pixels = next_atlas,
            .raster_size = raster_size,
            .atlas_width = atlas_width,
            .slots = next_slots[0..next_slot_count],
        });
        if (self.atlas.len != 0) {
            self.gpa.free(self.atlas);
        }
        self.atlas = next_atlas;
        self.atlas_width = atlas_width;
        self.atlas_height = atlas_height;
        self.pixel_width = raster_size.width;
        self.pixel_height = raster_size.height;
        @memcpy(self.slots[0..next_slot_count], next_slots[0..next_slot_count]);
        self.slot_count = next_slot_count;
        self.transfer_abort_pending = self.transfer_offset != 0;
        self.image_dirty = true;
        self.placements_dirty = true;
    }

    if (!icons.placementsEqual(
        self.placements[0..self.placement_count],
        next_placements[0..next_placement_count],
    )) {
        @memcpy(
            self.placements[0..next_placement_count],
            next_placements[0..next_placement_count],
        );
        self.placement_count = next_placement_count;
        self.placements_dirty = true;
    }
    if (!self.visible) {
        self.placements_dirty = true;
    }
    self.visible = true;
}

pub fn damaged(self: *const Renderer) bool {
    return self.transfer_abort_pending or self.transfer_offset != 0 or
        self.image_dirty or self.placements_dirty;
}

pub fn transferInProgress(self: *const Renderer) bool {
    return self.transfer_offset != 0;
}

pub fn write(self: *Renderer, writer: *std.Io.Writer) std.Io.Writer.Error!usize {
    if (!self.damaged()) {
        return 0;
    }
    var written: usize = 0;
    if (self.transfer_abort_pending) {
        written += try kitty_protocol.writeTransmissionAbort(writer);
        self.transfer_abort_pending = false;
        self.transfer_offset = 0;
    }

    if (!self.visible) {
        if (self.transfer_offset != 0) {
            written += try kitty_protocol.writeTransmissionAbort(writer);
            self.transfer_offset = 0;
        }
        if (self.image_emitted) {
            written += try kitty_protocol.writeDeleteImage(writer, icons.image_id);
        }
        self.image_emitted = false;
        self.image_dirty = false;
        self.placements_dirty = false;
        self.emitted_placement_count = 0;
        return written;
    }

    if (self.image_dirty) {
        if (self.transfer_offset == 0 and self.image_emitted) {
            written += try kitty_protocol.writeDeleteImage(writer, icons.image_id);
            self.image_emitted = false;
            self.emitted_placement_count = 0;
        }
        const progress = try kitty_codec.writeTransmissionChunks(writer, .{
            .external_id = icons.image_id,
            .image = .{
                .key = .{ .image_id = icons.image_id, .generation = 1 },
                .format = .rgba,
                .width = self.atlas_width,
                .height = self.atlas_height,
                .byte_len = self.atlas.len,
            },
            .pixels = self.atlas,
            .start_offset = self.transfer_offset,
            .budget = kitty_codec.transmission_budget_per_frame,
            .compressed = false,
        });
        written += progress.written;
        self.transfer_offset = progress.offset;
        if (progress.offset != self.atlas.len) {
            return written;
        }
        self.transfer_offset = 0;
        self.image_dirty = false;
        self.image_emitted = true;
    }

    if (self.placements_dirty and self.image_emitted) {
        for (0..self.emitted_placement_count) |index| {
            written += try kitty_protocol.writeDeletePlacement(
                writer,
                icons.image_id,
                icons.first_placement_id + @as(u32, @intCast(index)),
            );
        }
        for (self.placements[0..self.placement_count], 0..) |placement, index| {
            const columns: u32 = self.slots[placement.slot].columns;
            written += try kitty_codec.writePlacement(writer, .{
                .image_id = icons.image_id,
                .placement_id = icons.first_placement_id + @as(u32, @intCast(index)),
                .value = .{
                    .column = placement.area.x,
                    .row = placement.area.y,
                    .offset_x = 0,
                    .offset_y = 0,
                    .source_x = 0,
                    .source_y = @as(u32, placement.slot) * self.pixel_height,
                    .source_width = columns * self.pixel_width,
                    .source_height = self.pixel_height,
                    .columns = columns,
                    .rows = 1,
                },
                .z = icons.z_index,
            });
        }
        self.emitted_placement_count = self.placement_count;
        self.placements_dirty = false;
    }
    return written;
}
