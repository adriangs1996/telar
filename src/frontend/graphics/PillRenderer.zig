const data = @import("model");
const SidebarRendererInput = @import("SidebarRendererInput.zig");
const core = @import("telar-core");
const client = @import("telar-client");
const kitty_protocol = @import("kitty_protocol");
const std = @import("std");
const Rasterizer = @import("Rasterizer.zig");
const Plan = @import("../presentation/Plan.zig");
const pill = @import("pill.zig");
const kitty_codec = @import("kitty_codec.zig");
const labels = @import("../presentation/pane_labels.zig");
const Surface = @import("Surface.zig");
const rounded = @import("rounded_rectangle.zig");
const Renderer = @This();

gpa: std.mem.Allocator,
supported: bool = false,
cell_width: u16 = 0,
cell_height: u16 = 0,
text: ?Rasterizer = null,
pixels: []u8 = &.{},
plan: Plan = .{},
key: ?Key = null,
failed: bool = false,
generation: u64 = 0,
emitted_generation: u64 = 0,
desired: ?core.Rect = null,
emitted: ?core.Rect = null,
emitted_plan: Plan = .{},
emitted_key: ?Key = null,
emitted_image_id: u32 = pill.image_id,
image_dirty: bool = false,
image_emitted: bool = false,
transfer_offset: usize = 0,
abort_pending: bool = false,

pub fn init(gpa: std.mem.Allocator) Renderer {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Renderer) void {
    if (self.text) |*text| {
        text.deinit();
    }
    if (self.pixels.len != 0) {
        self.gpa.free(self.pixels);
    }
}

pub fn retainedBytes(self: *const Renderer) usize {
    return self.pixels.len;
}

/// Invalidates geometry without allocating on the input path.
/// Example: `_ = renderer.configure(configuration);`.
pub fn configure(self: *Renderer, configuration: SidebarRendererInput) bool {
    const supported = configuration.support == .supported;
    if (self.supported == supported and self.cell_width == configuration.cell_width and
        self.cell_height == configuration.cell_height)
    {
        return false;
    }

    self.hide();
    self.supported = supported;
    self.cell_width = configuration.cell_width;
    self.cell_height = configuration.cell_height;
    self.key = null;
    self.failed = false;
    return true;
}

/// Rasterizes the bounded, owned label snapshot only on the media pass.
/// Position-only changes reuse the image; text, focus or theme replace it.
/// Example: `renderer.prepare(plan, palette);`.
pub fn prepare(self: *Renderer, plan: *const Plan, palette: *const data.Palette) void {
    const key = self.renderKey(plan, palette) orelse {
        self.hide();
        return;
    };
    if (self.matches(plan, key)) {
        if (self.failed) {
            self.hide();
            return;
        }

        // Same content at a new position: keep the pixels, follow the area,
        // otherwise retirement compares the emitted placement against the
        // area of the plan that was rasterized and never settles.
        self.plan.area = plan.area;
        self.desired = plan.area;
        self.image_dirty = !self.image_emitted or self.generation != self.emitted_generation;
        return;
    }

    self.hide();
    self.key = key;
    self.plan = plan.*;
    self.generation +%= 1;
    self.failed = false;
    self.rasterize(key) catch {
        self.failed = true;
        return;
    };
    self.desired = plan.area;
    self.image_dirty = true;
}

/// Only exact text, focus, theme and geometry may replace fallback cells.
/// Example: `if (renderer.covers(plan, palette)) hideCellLabels();`.
pub fn covers(self: *const Renderer, plan: *const Plan, palette: *const data.Palette) bool {
    const key = self.renderKey(plan, palette) orelse return false;
    return self.matches(plan, key) and !self.failed and !self.transferInProgress() and
        self.image_emitted and !self.image_dirty and self.generation == self.emitted_generation and
        std.meta.eql(self.desired, @as(?core.Rect, plan.area)) and
        std.meta.eql(self.emitted, @as(?core.Rect, plan.area));
}

/// Keeps small-font text visible while only its selection is being replaced.
/// Unlike covers, this permits the previous focus but never stale text or geometry.
/// Example: `if (renderer.coversText(plan, palette)) hideCellLabels();`.
pub fn coversText(self: *const Renderer, plan: *const Plan, palette: *const data.Palette) bool {
    const key = self.renderKey(plan, palette) orelse return false;
    return !self.failed and self.image_emitted and
        std.meta.eql(self.desired, @as(?core.Rect, plan.area)) and self.emittedTextMatches(plan, key);
}

/// Retires stale text before the next cell frame, without rasterization.
/// Example: `renderer.observe(plan, palette);`.
pub fn observe(self: *Renderer, plan: *const Plan, palette: *const data.Palette) void {
    const key = self.renderKey(plan, palette) orelse {
        self.hide();
        return;
    };
    if ((!self.matches(plan, key) and !self.coversText(plan, palette)) or
        !std.meta.eql(self.desired, @as(?core.Rect, plan.area)))
    {
        self.hide();
    }
}

pub fn transferInProgress(self: *const Renderer) bool {
    return self.abort_pending or self.transfer_offset != 0;
}

pub fn retirementPending(self: *const Renderer) bool {
    return self.emitted != null and
        (!std.meta.eql(self.desired, self.emitted) or self.key == null or
            !self.emittedTextMatches(&self.plan, self.key.?));
}

/// Deletes stale placements only when no continuation is open.
/// Example: `_ = try renderer.writeRetirements(writer);`.
pub fn writeRetirements(self: *Renderer, writer: *std.Io.Writer) std.Io.Writer.Error!usize {
    if (!self.retirementPending() or self.transferInProgress()) {
        return 0;
    }

    const written = try kitty_protocol.writeDeletePlacement(writer, self.emitted_image_id, pill.placement_id);
    self.emitted = null;
    return written;
}

pub fn damaged(self: *const Renderer) bool {
    return self.transferInProgress() or self.retirementPending() or
        (self.desired != null and (self.image_dirty or self.emitted == null)) or
        (!self.supported and self.image_emitted);
}

/// Transfers at most one media budget. Continuations own the KGP stream
/// until completion or explicit cancellation, including across cell frames.
/// Example: `_ = try renderer.write(writer);`.
pub fn write(self: *Renderer, writer: *std.Io.Writer) std.Io.Writer.Error!usize {
    if (!self.damaged()) {
        return 0;
    }

    var written: usize = 0;
    if (self.abort_pending) {
        written += try kitty_protocol.writeTransmissionAbort(writer);
        self.abort_pending = false;
    }
    // A live continuation must finish before another graphics command.
    if (self.transfer_offset == 0) {
        written += try self.writeRetirements(writer);
    }
    if (!self.supported and self.image_emitted) {
        written += try kitty_protocol.writeDeleteImage(writer, self.emitted_image_id);
        self.image_emitted = false;
    }

    const area = self.desired orelse return written;
    const key = self.key orelse return written;
    const next_image_id = if (self.image_dirty) self.emitted_image_id ^ 1 else self.emitted_image_id;
    var replaced_image_id: ?u32 = null;
    if (self.image_dirty) {
        const progress = try kitty_codec.writeTransmissionChunks(writer, .{
            .external_id = next_image_id,
            .image = .{
                .key = .{ .image_id = pill.image_id, .generation = 1 },
                .format = .rgba,
                .width = key.width,
                .height = key.height,
                .byte_len = self.pixels.len,
            },
            .pixels = self.pixels,
            .start_offset = self.transfer_offset,
            .budget = kitty_codec.transmission_budget_per_frame -| written,
            .compressed = false,
        });
        written += progress.written;
        self.transfer_offset = progress.offset;
        if (progress.offset != self.pixels.len) {
            return written;
        }

        self.transfer_offset = 0;
        self.emitted_generation = self.generation;
        if (self.image_emitted) {
            replaced_image_id = self.emitted_image_id;
        }

        self.emitted_image_id = next_image_id;
        self.image_emitted = true;
        self.image_dirty = false;
    }

    written += try kitty_codec.writePlacement(writer, .{
        .image_id = self.emitted_image_id,
        .placement_id = pill.placement_id,
        .value = .{
            .column = area.x,
            .row = area.y,
            .offset_x = 0,
            .offset_y = (key.cell_height - key.height) / 2,
            .source_x = 0,
            .source_y = 0,
            .source_width = key.width,
            .source_height = key.height,
            .columns = 0,
            .rows = 0,
        },
        .z = -9,
    });

    // Place first, then delete the old image and its placement in the same frame.
    if (replaced_image_id) |previous| {
        written += try kitty_protocol.writeDeleteImage(writer, previous);
    }

    self.emitted = area;
    self.emitted_plan = self.plan;
    self.emitted_key = key;
    return written;
}

fn hide(self: *Renderer) void {
    if (self.transfer_offset != 0) {
        self.abort_pending = true;
        self.transfer_offset = 0;
    }

    self.desired = null;
    self.image_dirty = false;
}

fn emittedTextMatches(self: *const Renderer, plan: *const Plan, key: Key) bool {
    return self.emitted_key != null and std.meta.eql(self.emitted_key.?, key) and
        std.meta.eql(self.emitted, @as(?core.Rect, plan.area)) and self.emitted_plan.sameText(plan);
}

fn matches(self: *const Renderer, plan: *const Plan, key: Key) bool {
    return self.key != null and std.meta.eql(self.key.?, key) and self.plan.sameContent(plan);
}

fn renderKey(self: *const Renderer, plan: *const Plan, palette: *const data.Palette) ?Key {
    if (!self.supported or self.cell_width == 0 or self.cell_height < 8 or self.cell_height > 256 or
        plan.len == 0 or plan.len > core.max_panes_per_tab or plan.area.h != 1 or plan.area.w == 0 or
        palette.accent.kind != .rgb or palette.surface_dim.kind != .rgb or palette.subtext0.kind != .rgb)
    {
        return null;
    }

    const width = @as(u32, plan.area.w) * self.cell_width;
    const height: u16 = @intCast(@as(u32, self.cell_height) * 3 / 4);
    if (@as(u64, width) * height * 4 > pill.max_cache_bytes) {
        return null;
    }

    var selected: usize = 0;
    for (plan.slice()) |*label| {
        if (@as(u32, label.offset) + label.width > plan.area.w or label.len > labels.max_text_bytes or
            (label.selected and label.width < 4))
        {
            return null;
        }

        selected += @intFromBool(label.selected);
    }
    if (selected != 1) {
        return null;
    }

    return .{
        .width = width,
        .height = height,
        .cell_width = self.cell_width,
        .cell_height = self.cell_height,
        .font_height = @intCast(@min(@as(u32, height) * 2 / 3, @as(u32, self.cell_width) * 4 / 3)),
        .accent = palette.accent.value,
        .selected_text = palette.surface_dim.value,
        .inactive_text = palette.subtext0.value,
    };
}

fn rasterize(self: *Renderer, key: Key) !void {
    const len = @as(usize, key.width) * key.height * 4;
    if (self.pixels.len != len) {
        self.pixels = if (self.pixels.len == 0)
            try self.gpa.alloc(u8, len)
        else
            try self.gpa.realloc(self.pixels, len);
    }
    if (self.text == null) {
        self.text = try Rasterizer.init();
    }

    const text = &self.text.?;
    try text.setPixelHeight(key.font_height);
    @memset(self.pixels, 0);
    const metrics = text.metrics();
    const baseline = @divTrunc(@as(i32, key.height) - @as(i32, @intCast(metrics.line_height)), 2) + metrics.ascender;
    const surface: Surface = .{ .pixels = self.pixels, .width = key.width, .height = key.height };
    for (self.plan.slice()) |*label| {
        const available = @as(u32, label.width) * key.cell_width;
        const advance = try text.measureText(label.text());
        if (advance > available) {
            return error.LabelTooWide;
        }

        const start = @as(u32, label.offset) * key.cell_width;
        const origin = start + (available - advance) / 2;
        if (label.selected) {
            const padding = @min(@as(u32, key.font_height) / 2, (available - advance) / 2);
            const width = advance + padding * 2;
            const left = start + (available - width) / 2;
            rounded.render(.{
                .pixels = self.pixels[@as(usize, left) * 4 ..],
                .shape = .{ .size = .{ .width = width, .height = key.height }, .radius = key.height / 2 },
                .color = key.accent,
                .stride = key.width,
            });
        }

        const color = if (label.selected) key.selected_text else key.inactive_text;
        const drawn = try text.drawText(.{
            .surface = surface,
            .origin = .{ .x = @intCast(origin), .y = baseline },
            .text = label.text(),
            .color = .{ .red = color[0], .green = color[1], .blue = color[2] },
            .max_width = advance,
        });
        if (drawn != advance) {
            return error.LabelTooWide;
        }
    }
}

const Key = struct {
    width: u32,
    height: u16,
    cell_width: u16,
    cell_height: u16,
    font_height: u16,
    accent: [3]u8,
    selected_text: [3]u8,
    inactive_text: [3]u8,
};
