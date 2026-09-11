const Renderer = @This();
const std = @import("std");
const raster = @import("rasterizer_support.zig");
const labels = @import("../presentation/root.zig").pane_labels;
const Key = @import("Key.zig");
const source_namespace = @import("pill.zig");
const kitty = @import("kitty.zig");
const theme = @import("../ui/root.zig").theme;
const rounded = @import("rounded_rectangle.zig");
gpa: std.mem.Allocator,
supported: bool = false,
cell_width: u16 = 0,
cell_height: u16 = 0,
text: ?raster.Rasterizer = null,
pixels: []u8 = &.{},
plan: labels.Plan = .{},
key: ?Key = null,
failed: bool = false,
generation: u64 = 0,
emitted_generation: u64 = 0,
desired: ?source_namespace.ui.Rect = null,
emitted: ?source_namespace.ui.Rect = null,
emitted_plan: labels.Plan = .{},
emitted_key: ?Key = null,
emitted_image_id: u32 = source_namespace.image_id,
image_dirty: bool = false,
image_emitted: bool = false,
transfer_offset: usize = 0,
abort_pending: bool = false,

pub fn init(gpa: std.mem.Allocator) Renderer {
    return .{ .gpa = gpa };
}

pub fn deinit(renderer: *Renderer) void {
    if (renderer.text) |*text| {
        text.deinit();
    }
    if (renderer.pixels.len != 0) {
        renderer.gpa.free(renderer.pixels);
    }
}

pub fn retainedBytes(renderer: *const Renderer) usize {
    return renderer.pixels.len;
}

/// Invalidates geometry without allocating on the input path.
/// Example: `_ = renderer.configure(configuration);`.
pub fn configure(renderer: *Renderer, configuration: kitty.Configuration) bool {
    const supported = configuration.support == .supported;
    if (renderer.supported == supported and renderer.cell_width == configuration.cell_width and
        renderer.cell_height == configuration.cell_height)
    {
        return false;
    }

    renderer.hide();
    renderer.supported = supported;
    renderer.cell_width = configuration.cell_width;
    renderer.cell_height = configuration.cell_height;
    renderer.key = null;
    renderer.failed = false;
    return true;
}

/// Rasterizes the bounded, owned label snapshot only on the media pass.
/// Position-only changes reuse the image; text, focus or theme replace it.
/// Example: `renderer.prepare(plan, palette);`.
pub fn prepare(renderer: *Renderer, plan: *const labels.Plan, palette: *const theme.Palette) void {
    const key = renderer.renderKey(plan, palette) orelse {
        renderer.hide();
        return;
    };
    if (renderer.matches(plan, key)) {
        if (renderer.failed) {
            renderer.hide();
            return;
        }

        renderer.desired = plan.area;
        renderer.image_dirty = !renderer.image_emitted or renderer.generation != renderer.emitted_generation;
        return;
    }

    renderer.hide();
    renderer.key = key;
    renderer.plan = plan.*;
    renderer.generation +%= 1;
    renderer.failed = false;
    renderer.rasterize(key) catch {
        renderer.failed = true;
        return;
    };
    renderer.desired = plan.area;
    renderer.image_dirty = true;
}

/// Only exact text, focus, theme and geometry may replace fallback cells.
/// Example: `if (renderer.covers(plan, palette)) hideCellLabels();`.
pub fn covers(renderer: *const Renderer, plan: *const labels.Plan, palette: *const theme.Palette) bool {
    const key = renderer.renderKey(plan, palette) orelse return false;
    return renderer.matches(plan, key) and !renderer.failed and !renderer.transferInProgress() and
        renderer.image_emitted and !renderer.image_dirty and renderer.generation == renderer.emitted_generation and
        std.meta.eql(renderer.desired, @as(?source_namespace.ui.Rect, plan.area)) and
        std.meta.eql(renderer.emitted, @as(?source_namespace.ui.Rect, plan.area));
}

/// Keeps small-font text visible while only its selection is being replaced.
/// Unlike covers, this permits the previous focus but never stale text or geometry.
/// Example: `if (renderer.coversText(plan, palette)) hideCellLabels();`.
pub fn coversText(renderer: *const Renderer, plan: *const labels.Plan, palette: *const theme.Palette) bool {
    const key = renderer.renderKey(plan, palette) orelse return false;
    return !renderer.failed and renderer.image_emitted and
        std.meta.eql(renderer.desired, @as(?source_namespace.ui.Rect, plan.area)) and renderer.emittedTextMatches(plan, key);
}

/// Retires stale text before the next cell frame, without rasterization.
/// Example: `renderer.observe(plan, palette);`.
pub fn observe(renderer: *Renderer, plan: *const labels.Plan, palette: *const theme.Palette) void {
    const key = renderer.renderKey(plan, palette) orelse {
        renderer.hide();
        return;
    };
    if ((!renderer.matches(plan, key) and !renderer.coversText(plan, palette)) or
        !std.meta.eql(renderer.desired, @as(?source_namespace.ui.Rect, plan.area)))
    {
        renderer.hide();
    }
}

pub fn transferInProgress(renderer: *const Renderer) bool {
    return renderer.abort_pending or renderer.transfer_offset != 0;
}

pub fn retirementPending(renderer: *const Renderer) bool {
    return renderer.emitted != null and
        (!std.meta.eql(renderer.desired, renderer.emitted) or renderer.key == null or
            !renderer.emittedTextMatches(&renderer.plan, renderer.key.?));
}

/// Deletes stale placements only when no continuation is open.
/// Example: `_ = try renderer.writeRetirements(writer);`.
pub fn writeRetirements(renderer: *Renderer, writer: *source_namespace.Io.Writer) source_namespace.Io.Writer.Error!usize {
    if (!renderer.retirementPending() or renderer.transferInProgress()) {
        return 0;
    }

    const written = try kitty.writeDeletePlacement(writer, renderer.emitted_image_id, source_namespace.placement_id);
    renderer.emitted = null;
    return written;
}

pub fn damaged(renderer: *const Renderer) bool {
    return renderer.transferInProgress() or renderer.retirementPending() or
        (renderer.desired != null and (renderer.image_dirty or renderer.emitted == null)) or
        (!renderer.supported and renderer.image_emitted);
}

/// Transfers at most one media budget. Continuations own the KGP stream
/// until completion or explicit cancellation, including across cell frames.
/// Example: `_ = try renderer.write(writer);`.
pub fn write(renderer: *Renderer, writer: *source_namespace.Io.Writer) source_namespace.Io.Writer.Error!usize {
    if (!renderer.damaged()) {
        return 0;
    }

    var written: usize = 0;
    if (renderer.abort_pending) {
        written += try kitty.writeTransmissionAbort(writer);
        renderer.abort_pending = false;
    }
    // A live continuation must finish before another graphics command.
    if (renderer.transfer_offset == 0) {
        written += try renderer.writeRetirements(writer);
    }
    if (!renderer.supported and renderer.image_emitted) {
        written += try kitty.writeDeleteImage(writer, renderer.emitted_image_id);
        renderer.image_emitted = false;
    }

    const area = renderer.desired orelse return written;
    const key = renderer.key orelse return written;
    const next_image_id = if (renderer.image_dirty) renderer.emitted_image_id ^ 1 else renderer.emitted_image_id;
    var replaced_image_id: ?u32 = null;
    if (renderer.image_dirty) {
        const progress = try kitty.writeTransmissionChunks(writer, .{
            .external_id = next_image_id,
            .image = .{
                .key = .{ .image_id = source_namespace.image_id, .generation = 1 },
                .format = .rgba,
                .width = key.width,
                .height = key.height,
                .byte_len = renderer.pixels.len,
            },
            .pixels = renderer.pixels,
            .start_offset = renderer.transfer_offset,
            .budget = kitty.transmission_budget_per_frame -| written,
            .compressed = false,
        });
        written += progress.written;
        renderer.transfer_offset = progress.offset;
        if (progress.offset != renderer.pixels.len) {
            return written;
        }

        renderer.transfer_offset = 0;
        renderer.emitted_generation = renderer.generation;
        if (renderer.image_emitted) {
            replaced_image_id = renderer.emitted_image_id;
        }

        renderer.emitted_image_id = next_image_id;
        renderer.image_emitted = true;
        renderer.image_dirty = false;
    }

    written += try kitty.writePlacement(writer, .{
        .image_id = renderer.emitted_image_id,
        .placement_id = source_namespace.placement_id,
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
        written += try kitty.writeDeleteImage(writer, previous);
    }

    renderer.emitted = area;
    renderer.emitted_plan = renderer.plan;
    renderer.emitted_key = key;
    return written;
}

fn hide(renderer: *Renderer) void {
    if (renderer.transfer_offset != 0) {
        renderer.abort_pending = true;
        renderer.transfer_offset = 0;
    }

    renderer.desired = null;
    renderer.image_dirty = false;
}

fn emittedTextMatches(renderer: *const Renderer, plan: *const labels.Plan, key: Key) bool {
    return renderer.emitted_key != null and std.meta.eql(renderer.emitted_key.?, key) and
        std.meta.eql(renderer.emitted, @as(?source_namespace.ui.Rect, plan.area)) and renderer.emitted_plan.sameText(plan);
}

fn matches(renderer: *const Renderer, plan: *const labels.Plan, key: Key) bool {
    return renderer.key != null and std.meta.eql(renderer.key.?, key) and renderer.plan.sameContent(plan);
}

fn renderKey(renderer: *const Renderer, plan: *const labels.Plan, palette: *const theme.Palette) ?Key {
    if (!renderer.supported or renderer.cell_width == 0 or renderer.cell_height < 8 or renderer.cell_height > 256 or
        plan.len == 0 or plan.len > labels.max_labels or plan.area.h != 1 or plan.area.w == 0 or
        palette.accent != .rgb or palette.surface_dim != .rgb or palette.subtext0 != .rgb)
    {
        return null;
    }

    const width = @as(u32, plan.area.w) * renderer.cell_width;
    const height: u16 = @intCast(@as(u32, renderer.cell_height) * 3 / 4);
    if (@as(u64, width) * height * 4 > source_namespace.max_cache_bytes) {
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
        .cell_width = renderer.cell_width,
        .cell_height = renderer.cell_height,
        .font_height = @intCast(@min(@as(u32, height) * 2 / 3, @as(u32, renderer.cell_width) * 4 / 3)),
        .accent = palette.accent.rgb,
        .selected_text = palette.surface_dim.rgb,
        .inactive_text = palette.subtext0.rgb,
    };
}

fn rasterize(renderer: *Renderer, key: Key) !void {
    const len = @as(usize, key.width) * key.height * 4;
    if (renderer.pixels.len != len) {
        renderer.pixels = if (renderer.pixels.len == 0)
            try renderer.gpa.alloc(u8, len)
        else
            try renderer.gpa.realloc(renderer.pixels, len);
    }
    if (renderer.text == null) {
        renderer.text = try raster.Rasterizer.init();
    }

    const text = &renderer.text.?;
    try text.setPixelHeight(key.font_height);
    @memset(renderer.pixels, 0);
    const metrics = text.metrics();
    const baseline = @divTrunc(@as(i32, key.height) - @as(i32, @intCast(metrics.line_height)), 2) + metrics.ascender;
    const surface: raster.Surface = .{ .pixels = renderer.pixels, .width = key.width, .height = key.height };
    for (renderer.plan.slice()) |*label| {
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
                .pixels = renderer.pixels[@as(usize, left) * 4 ..],
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
