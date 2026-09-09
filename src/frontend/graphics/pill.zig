//! Small JetBrains Mono labels and the selected pill inside the pane border.
//! Client-owned media in two layers: a text strip that changes only with the
//! label text, geometry or theme, and a small selection pill placed over it
//! that follows focus. A focus change therefore rasterizes and transmits one
//! label's pill, never the strip. Each layer keeps one <=1 MiB RGBA buffer
//! and two bounded host image slots; the old pill stays visible until the
//! new one is placed. Text, geometry and theme changes still fall back to
//! cells; latest plan wins.

const std = @import("std");
const core = @import("telar-core");
const kitty = @import("kitty.zig");
const rounded = @import("rounded_rectangle.zig");
const raster = @import("rasterizer.zig");
const labels = @import("../presentation/root.zig").pane_labels;
const theme = @import("../ui/root.zig").theme;
const ui = core.ui;
const Io = std.Io;

pub const max_cache_bytes = 1024 * 1024;
const strip_image_id: u32 = 0x80003000;
const strip_placement_id: u32 = 0x80003100;
const pill_image_id: u32 = 0x80003002;
const pill_placement_id: u32 = 0x80003101;
/// The strip sits under cells; the pill sits between the strip and cells.
const strip_z: i32 = -9;
const pill_z: i32 = -8;

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

/// Pixel geometry of the selected label's pill inside the strip.
const PillShape = struct {
    /// Pixels from the strip's left edge.
    left: u32,
    width: u32,
    /// Text advance inside the pill; padding is shared on both sides.
    advance: u32,
};

/// Where a layer's image is drawn: the host cell plus a pixel offset inside it.
const Slot = struct {
    column: u32,
    row: u32,
    offset_x: u32,
    offset_y: u32,
    width: u32,
    height: u32,
};

/// One host image with its chunked transfer, alternating image ids and a
/// single placement. The renderer decides what each layer shows; the layer
/// only knows how to get pixels to the host and keep the old picture up
/// until the new one is placed.
const Layer = struct {
    image_id: u32,
    placement_id: u32,
    z: i32,
    pixels: []u8 = &.{},
    width: u32 = 0,
    height: u16 = 0,
    generation: u64 = 0,
    emitted_generation: u64 = 0,
    desired: ?Slot = null,
    emitted: ?Slot = null,
    emitted_image_id: u32,
    image_dirty: bool = false,
    image_emitted: bool = false,
    transfer_offset: usize = 0,
    abort_pending: bool = false,
    /// Retire the emitted placement before the next cell frame even though
    /// the layer still wants a picture: its content no longer matches what
    /// the cells will show underneath.
    stale: bool = false,
    /// Whether a moved placement is retired ahead of its re-placement. The
    /// strip is, because cells redraw the labels meanwhile; the pill is not,
    /// so the old pill stays visible until the new one is placed.
    retire_on_move: bool,

    fn init(image_id: u32, placement_id: u32, z: i32) Layer {
        return .{
            .image_id = image_id,
            .placement_id = placement_id,
            .z = z,
            .emitted_image_id = image_id,
            .retire_on_move = z == strip_z,
        };
    }

    fn deinit(layer: *Layer, gpa: std.mem.Allocator) void {
        if (layer.pixels.len != 0) {
            gpa.free(layer.pixels);
        }
    }

    fn reservePixels(layer: *Layer, gpa: std.mem.Allocator, len: usize) ![]u8 {
        if (layer.pixels.len != len) {
            layer.pixels = if (layer.pixels.len == 0)
                try gpa.alloc(u8, len)
            else
                try gpa.realloc(layer.pixels, len);
        }
        return layer.pixels;
    }

    fn hide(layer: *Layer) void {
        if (layer.transfer_offset != 0) {
            layer.abort_pending = true;
            layer.transfer_offset = 0;
        }

        layer.desired = null;
        layer.image_dirty = false;
    }

    fn transferInProgress(layer: *const Layer) bool {
        return layer.abort_pending or layer.transfer_offset != 0;
    }

    fn placed(layer: *const Layer, slot: Slot) bool {
        return layer.image_emitted and !layer.image_dirty and layer.generation == layer.emitted_generation and
            std.meta.eql(layer.desired, @as(?Slot, slot)) and std.meta.eql(layer.emitted, @as(?Slot, slot));
    }

    fn retirementPending(layer: *const Layer) bool {
        const emitted = layer.emitted orelse return false;
        if (layer.stale or layer.desired == null) {
            return true;
        }
        return layer.retire_on_move and !std.meta.eql(layer.desired.?, emitted);
    }

    fn writeRetirements(layer: *Layer, writer: *Io.Writer) Io.Writer.Error!usize {
        if (!layer.retirementPending() or layer.transferInProgress()) {
            return 0;
        }

        const written = try kitty.writeDeletePlacement(writer, layer.emitted_image_id, layer.placement_id);
        layer.emitted = null;
        layer.stale = false;
        return written;
    }

    fn damaged(layer: *const Layer) bool {
        return layer.transferInProgress() or layer.retirementPending() or
            (layer.desired != null and (layer.image_dirty or layer.emitted == null));
    }

    fn writeDeleteImages(layer: *Layer, writer: *Io.Writer) Io.Writer.Error!usize {
        if (!layer.image_emitted) {
            return 0;
        }

        const written = try kitty.writeDeleteImage(writer, layer.emitted_image_id);
        layer.image_emitted = false;
        layer.emitted = null;
        layer.stale = false;
        return written;
    }

    /// Transfers at most `budget` bytes of a dirty image, then places it.
    /// A continuation owns the KGP stream until it completes.
    fn write(layer: *Layer, writer: *Io.Writer, budget: usize) Io.Writer.Error!usize {
        var written: usize = 0;
        if (layer.abort_pending) {
            written += try kitty.writeTransmissionAbort(writer);
            layer.abort_pending = false;
        }
        if (layer.transfer_offset == 0) {
            written += try layer.writeRetirements(writer);
        }

        const slot = layer.desired orelse return written;
        const next_image_id = if (layer.image_dirty) layer.emitted_image_id ^ 1 else layer.emitted_image_id;
        var replaced_image_id: ?u32 = null;
        if (layer.image_dirty) {
            const progress = try kitty.writeTransmissionChunks(writer, .{
                .external_id = next_image_id,
                .image = .{
                    .key = .{ .image_id = layer.image_id, .generation = 1 },
                    .format = .rgba,
                    .width = layer.width,
                    .height = layer.height,
                    .byte_len = layer.pixels.len,
                },
                .pixels = layer.pixels,
                .start_offset = layer.transfer_offset,
                .budget = budget -| written,
                .compressed = false,
            });
            written += progress.written;
            layer.transfer_offset = progress.offset;
            if (progress.offset != layer.pixels.len) {
                return written;
            }

            layer.transfer_offset = 0;
            layer.emitted_generation = layer.generation;
            if (layer.image_emitted) {
                replaced_image_id = layer.emitted_image_id;
            }

            layer.emitted_image_id = next_image_id;
            layer.image_emitted = true;
            layer.image_dirty = false;
        } else if (std.meta.eql(layer.emitted, @as(?Slot, slot))) {
            return written;
        }

        written += try kitty.writePlacement(writer, .{
            .image_id = layer.emitted_image_id,
            .placement_id = layer.placement_id,
            .value = .{
                .column = slot.column,
                .row = slot.row,
                .offset_x = slot.offset_x,
                .offset_y = slot.offset_y,
                .source_x = 0,
                .source_y = 0,
                .source_width = slot.width,
                .source_height = slot.height,
                .columns = 0,
                .rows = 0,
            },
            .z = layer.z,
        });

        // Place first, then delete the old image and its placement in the same frame.
        if (replaced_image_id) |previous| {
            written += try kitty.writeDeleteImage(writer, previous);
        }

        layer.emitted = slot;
        layer.stale = false;
        return written;
    }
};

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    supported: bool = false,
    cell_width: u16 = 0,
    cell_height: u16 = 0,
    text: ?raster.Rasterizer = null,
    strip: Layer = Layer.init(strip_image_id, strip_placement_id, strip_z),
    pill: Layer = Layer.init(pill_image_id, pill_placement_id, pill_z),
    plan: labels.Plan = .{},
    key: ?Key = null,
    /// The label whose pill is rasterized, with its shape inside the strip.
    pill_label: ?labels.Label = null,
    pill_shape: PillShape = .{ .left = 0, .width = 0, .advance = 0 },
    failed: bool = false,
    emitted_plan: labels.Plan = .{},
    emitted_key: ?Key = null,
    /// A rasterization was needed while the user was typing; the current
    /// images stay up and the change runs after the idle boundary.
    deferred: bool = false,

    pub fn init(gpa: std.mem.Allocator) Renderer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(renderer: *Renderer) void {
        if (renderer.text) |*text| {
            text.deinit();
        }
        renderer.strip.deinit(renderer.gpa);
        renderer.pill.deinit(renderer.gpa);
    }

    pub fn retainedBytes(renderer: *const Renderer) usize {
        return renderer.strip.pixels.len + renderer.pill.pixels.len;
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
        renderer.pill_label = null;
        renderer.failed = false;
        return true;
    }

    /// Rasterizes the bounded, owned label snapshot only on the media pass.
    /// Position-only changes reuse both images; a focus change replaces the
    /// pill alone; text, geometry or theme replace the strip as well.
    /// Example: `renderer.prepare(plan, palette);`.
    pub fn prepare(renderer: *Renderer, plan: *const labels.Plan, palette: *const theme.Palette) void {
        renderer.preparePaced(.{ .plan = plan, .palette = palette, .media_idle = true });
    }

    pub const Preparation = struct {
        plan: *const labels.Plan,
        palette: *const theme.Palette,
        /// Rasterization may run now; otherwise the change waits for idle.
        media_idle: bool,
    };

    /// Whether a needed rasterization is waiting for the idle boundary.
    /// Example: `if (renderer.preparationDeferred()) requestMediaAfterIdle();`.
    pub fn preparationDeferred(renderer: *const Renderer) bool {
        return renderer.deferred;
    }

    /// Like `prepare`, but text or pill rasterization runs only while
    /// `media_idle`; otherwise what the host shows stays and the change waits.
    ///
    /// ```zig
    /// renderer.preparePaced(.{ .plan = plan, .palette = palette, .media_idle = media_idle });
    /// ```
    pub fn preparePaced(renderer: *Renderer, preparation: Preparation) void {
        const plan = preparation.plan;
        const palette = preparation.palette;
        const media_idle = preparation.media_idle;
        const key = renderer.renderKey(plan, palette) orelse {
            renderer.deferred = false;
            renderer.hide();
            return;
        };
        if (renderer.failed and renderer.matchesText(plan, key)) {
            renderer.deferred = false;
            renderer.hide();
            return;
        }
        if (!media_idle and renderer.rasterizationNeeded(plan, key)) {
            renderer.deferred = true;
            return;
        }
        renderer.deferred = false;

        if (!renderer.matchesText(plan, key)) {
            renderer.strip.hide();
            renderer.pill.hide();
            // Cells redraw the new labels on the next frame, so whatever the
            // host still shows for the old text must leave with that frame.
            renderer.strip.stale = renderer.strip.emitted != null;
            renderer.pill.stale = renderer.pill.emitted != null;
            renderer.key = key;
            renderer.plan = plan.*;
            renderer.pill_label = null;
            renderer.failed = false;
            renderer.strip.generation +%= 1;
            renderer.rasterizeStrip(key) catch {
                renderer.failed = true;
                return;
            };
            renderer.strip.image_dirty = true;
        } else {
            renderer.plan = plan.*;
            renderer.strip.image_dirty = !renderer.strip.image_emitted or
                renderer.strip.generation != renderer.strip.emitted_generation;
        }
        renderer.strip.desired = stripSlot(plan.area, key);

        const selected = selectedLabel(plan) orelse {
            renderer.pill.hide();
            return;
        };
        const shape = pillShape(renderer.textRasterizer(), selected, key) catch {
            renderer.failed = true;
            renderer.hide();
            return;
        };
        if (!renderer.matchesPill(selected, shape)) {
            renderer.pill.hide();
            renderer.pill.generation +%= 1;
            renderer.rasterizePill(.{ .label = selected, .shape = shape, .key = key }) catch {
                renderer.failed = true;
                renderer.hide();
                return;
            };
            renderer.pill_label = selected;
            renderer.pill_shape = shape;
            renderer.pill.image_dirty = true;
        } else {
            renderer.pill.image_dirty = !renderer.pill.image_emitted or
                renderer.pill.generation != renderer.pill.emitted_generation;
        }
        renderer.pill.desired = pillSlot(plan.area, shape, key);
    }

    /// Only exact text, focus, theme and geometry may replace fallback cells.
    /// Example: `if (renderer.covers(plan, palette)) hideCellLabels();`.
    pub fn covers(renderer: *const Renderer, plan: *const labels.Plan, palette: *const theme.Palette) bool {
        const key = renderer.renderKey(plan, palette) orelse return false;
        if (!renderer.coversText(plan, palette) or renderer.transferInProgress()) {
            return false;
        }

        const selected = selectedLabel(plan) orelse return false;
        const pill_label = renderer.pill_label orelse return false;
        return labelsEqual(&pill_label, &selected) and
            renderer.pill.placed(pillSlot(plan.area, renderer.pill_shape, key));
    }

    /// Keeps small-font text visible while only its selection is being replaced.
    /// Unlike covers, this permits the previous focus but never stale text or geometry.
    /// Example: `if (renderer.coversText(plan, palette)) hideCellLabels();`.
    pub fn coversText(renderer: *const Renderer, plan: *const labels.Plan, palette: *const theme.Palette) bool {
        const key = renderer.renderKey(plan, palette) orelse return false;
        return !renderer.failed and renderer.strip.image_emitted and
            std.meta.eql(renderer.strip.desired, @as(?Slot, stripSlot(plan.area, key))) and
            renderer.emittedTextMatches(plan, key);
    }

    /// Retires stale text before the next cell frame, without rasterization.
    /// Example: `renderer.observe(plan, palette);`.
    pub fn observe(renderer: *Renderer, plan: *const labels.Plan, palette: *const theme.Palette) void {
        const key = renderer.renderKey(plan, palette) orelse {
            renderer.hide();
            return;
        };
        if ((!renderer.matchesText(plan, key) and !renderer.coversText(plan, palette)) or
            !std.meta.eql(renderer.strip.desired, @as(?Slot, stripSlot(plan.area, key))))
        {
            renderer.hide();
        }
    }

    pub fn transferInProgress(renderer: *const Renderer) bool {
        return renderer.strip.transferInProgress() or renderer.pill.transferInProgress();
    }

    pub fn retirementPending(renderer: *const Renderer) bool {
        return renderer.strip.retirementPending() or renderer.pill.retirementPending();
    }

    /// Deletes stale placements only when no continuation is open.
    /// Example: `_ = try renderer.writeRetirements(writer);`.
    pub fn writeRetirements(renderer: *Renderer, writer: *Io.Writer) Io.Writer.Error!usize {
        if (renderer.transferInProgress()) {
            return 0;
        }

        return (try renderer.strip.writeRetirements(writer)) + (try renderer.pill.writeRetirements(writer));
    }

    pub fn damaged(renderer: *const Renderer) bool {
        return renderer.strip.damaged() or renderer.pill.damaged() or
            (!renderer.supported and (renderer.strip.image_emitted or renderer.pill.image_emitted));
    }

    /// Transfers at most one media budget. The strip goes first; the pill
    /// follows only once no strip continuation is open, so the two images
    /// never interleave chunks on the KGP stream.
    /// Example: `_ = try renderer.write(writer);`.
    pub fn write(renderer: *Renderer, writer: *Io.Writer) Io.Writer.Error!usize {
        if (!renderer.damaged()) {
            return 0;
        }

        var written: usize = 0;
        if (!renderer.supported) {
            written += try renderer.strip.writeDeleteImages(writer);
            written += try renderer.pill.writeDeleteImages(writer);
        }
        if (renderer.pill.transferInProgress()) {
            written += try renderer.pill.write(writer, kitty.transmission_budget_per_frame);
            return written;
        }

        written += try renderer.strip.write(writer, kitty.transmission_budget_per_frame);
        if (renderer.strip.transferInProgress()) {
            return written;
        }

        written += try renderer.pill.write(writer, kitty.transmission_budget_per_frame -| written);
        if (renderer.strip.emitted != null) {
            renderer.emitted_plan = renderer.plan;
            renderer.emitted_key = renderer.key;
        }
        return written;
    }

    fn hide(renderer: *Renderer) void {
        renderer.strip.hide();
        renderer.pill.hide();
    }

    fn textRasterizer(renderer: *Renderer) *?raster.Rasterizer {
        return &renderer.text;
    }

    fn emittedTextMatches(renderer: *const Renderer, plan: *const labels.Plan, key: Key) bool {
        return renderer.emitted_key != null and std.meta.eql(renderer.emitted_key.?, key) and
            std.meta.eql(renderer.strip.emitted, @as(?Slot, stripSlot(plan.area, key))) and
            renderer.emitted_plan.sameText(plan);
    }

    fn rasterizationNeeded(renderer: *Renderer, plan: *const labels.Plan, key: Key) bool {
        if (!renderer.matchesText(plan, key)) {
            return true;
        }
        const selected = selectedLabel(plan) orelse return false;
        const shape = pillShape(renderer.textRasterizer(), selected, key) catch return true;
        return !renderer.matchesPill(selected, shape);
    }

    fn matchesText(renderer: *const Renderer, plan: *const labels.Plan, key: Key) bool {
        return renderer.key != null and std.meta.eql(renderer.key.?, key) and renderer.plan.sameText(plan);
    }

    fn matchesPill(renderer: *const Renderer, selected: labels.Label, shape: PillShape) bool {
        const current = renderer.pill_label orelse return false;
        return labelsEqual(&current, &selected) and renderer.pill_shape.width == shape.width and
            renderer.pill_shape.advance == shape.advance;
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
        if (@as(u64, width) * height * 4 > max_cache_bytes) {
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

    /// Draws every label in the inactive color. The selected label's pill
    /// covers its text with the accent picture, so focus never enters here.
    fn rasterizeStrip(renderer: *Renderer, key: Key) !void {
        const len = @as(usize, key.width) * key.height * 4;
        const pixels = try renderer.strip.reservePixels(renderer.gpa, len);
        renderer.strip.width = key.width;
        renderer.strip.height = key.height;
        const text = try ensureRasterizer(renderer.textRasterizer());
        try text.setPixelHeight(key.font_height);
        @memset(pixels, 0);
        const baseline = textBaseline(text, key);
        const surface: raster.Surface = .{ .pixels = pixels, .width = key.width, .height = key.height };
        for (renderer.plan.slice()) |*label| {
            const available = @as(u32, label.width) * key.cell_width;
            const advance = try text.measureText(label.text());
            if (advance > available) {
                return error.LabelTooWide;
            }

            const origin = @as(u32, label.offset) * key.cell_width + (available - advance) / 2;
            const drawn = try text.drawText(.{
                .surface = surface,
                .origin = .{ .x = @intCast(origin), .y = baseline },
                .text = label.text(),
                .color = .{ .red = key.inactive_text[0], .green = key.inactive_text[1], .blue = key.inactive_text[2] },
                .max_width = advance,
            });
            if (drawn != advance) {
                return error.LabelTooWide;
            }
        }
    }

    const PillRaster = struct {
        label: labels.Label,
        shape: PillShape,
        key: Key,
    };

    /// Draws one accent pill with the selected label's text in it. The image
    /// is only as wide as that pill.
    fn rasterizePill(renderer: *Renderer, input: PillRaster) !void {
        const key = input.key;
        const shape = input.shape;
        const len = @as(usize, shape.width) * key.height * 4;
        const pixels = try renderer.pill.reservePixels(renderer.gpa, len);
        renderer.pill.width = shape.width;
        renderer.pill.height = key.height;
        const text = try ensureRasterizer(renderer.textRasterizer());
        try text.setPixelHeight(key.font_height);
        rounded.render(.{
            .pixels = pixels,
            .shape = .{ .size = .{ .width = shape.width, .height = key.height }, .radius = key.height / 2 },
            .color = key.accent,
            .stride = shape.width,
        });
        const drawn = try text.drawText(.{
            .surface = .{ .pixels = pixels, .width = shape.width, .height = key.height },
            .origin = .{ .x = @intCast((shape.width - shape.advance) / 2), .y = textBaseline(text, key) },
            .text = input.label.text(),
            .color = .{ .red = key.selected_text[0], .green = key.selected_text[1], .blue = key.selected_text[2] },
            .max_width = shape.advance,
        });
        if (drawn != shape.advance) {
            return error.LabelTooWide;
        }
    }
};

fn ensureRasterizer(slot: *?raster.Rasterizer) !*raster.Rasterizer {
    if (slot.* == null) {
        slot.* = try raster.Rasterizer.init();
    }
    return &slot.*.?;
}

fn textBaseline(text: *raster.Rasterizer, key: Key) i32 {
    const metrics = text.metrics();
    return @divTrunc(@as(i32, key.height) - @as(i32, @intCast(metrics.line_height)), 2) + metrics.ascender;
}

fn selectedLabel(plan: *const labels.Plan) ?labels.Label {
    for (plan.slice()) |label| {
        if (label.selected) {
            return label;
        }
    }
    return null;
}

fn labelsEqual(a: *const labels.Label, b: *const labels.Label) bool {
    return a.offset == b.offset and a.width == b.width and std.mem.eql(u8, a.text(), b.text());
}

/// Measures the selected label to size its pill: the text advance plus equal
/// padding, centered in the label's cells. Needs the font at the key's size.
fn pillShape(slot: *?raster.Rasterizer, label: labels.Label, key: Key) !PillShape {
    const text = try ensureRasterizer(slot);
    try text.setPixelHeight(key.font_height);
    const available = @as(u32, label.width) * key.cell_width;
    const advance = try text.measureText(label.text());
    if (advance > available) {
        return error.LabelTooWide;
    }

    const padding = @min(@as(u32, key.font_height) / 2, (available - advance) / 2);
    const width = advance + padding * 2;
    const start = @as(u32, label.offset) * key.cell_width;
    return .{ .left = start + (available - width) / 2, .width = width, .advance = advance };
}

fn stripSlot(area: ui.Rect, key: Key) Slot {
    return .{
        .column = area.x,
        .row = area.y,
        .offset_x = 0,
        .offset_y = (key.cell_height - key.height) / 2,
        .width = key.width,
        .height = key.height,
    };
}

fn pillSlot(area: ui.Rect, shape: PillShape, key: Key) Slot {
    return .{
        .column = area.x + shape.left / key.cell_width,
        .row = area.y,
        .offset_x = shape.left % key.cell_width,
        .offset_y = (key.cell_height - key.height) / 2,
        .width = shape.width,
        .height = key.height,
    };
}

fn testingPlan(names: []const []const u8, selected: usize) labels.Plan {
    var plan: labels.Plan = .{ .area = .{ .x = 2, .y = 1, .h = 1 } };
    for (names, 0..) |name, index| {
        var label: labels.Label = .{ .offset = plan.area.w, .width = 0, .selected = index == selected };
        const text = std.fmt.bufPrint(&label.bytes, "{d} {s}", .{ index + 1, name }) catch unreachable;
        label.len = @intCast(text.len);
        label.width = ui.measure(text) + 2;
        plan.labels[plan.len] = label;
        plan.len += 1;
        plan.area.w += label.width + @as(u16, @intFromBool(index + 1 != names.len));
    }

    return plan;
}

test "small labels use JetBrains Mono and a centered three-quarter-height pill" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    const palette = &theme.default_theme.palette;
    _ = renderer.configure(.{ .support = .supported, .cell_width = 22, .cell_height = 58 });
    var plan = testingPlan(&.{ "zsh", "nvim", "Pi" }, 1);
    renderer.prepare(&plan, palette);
    try std.testing.expect(!renderer.failed);
    try std.testing.expectEqual(@as(u16, 43), renderer.key.?.height);
    try std.testing.expectEqual(@as(u16, 28), renderer.key.?.font_height);
    try std.testing.expect(renderer.text != null);
    try std.testing.expect(!renderer.covers(&plan, palette));

    // Strip glyphs have straight-alpha inactive RGB, not a preblended dark edge.
    var text_pixels: usize = 0;
    const width = renderer.key.?.width;
    for (0..renderer.key.?.height) |y| {
        for (0..@as(usize, plan.labels[0].width) * renderer.cell_width) |x| {
            const pixel = renderer.strip.pixels[(y * width + x) * 4 ..][0..4];
            if (pixel[3] != 0) {
                try std.testing.expectEqualSlices(u8, &palette.subtext0.rgb, pixel[0..3]);
                text_pixels += 1;
            }
        }
    }
    try std.testing.expect(text_pixels != 0);

    // The pill is opaque accent in its middle and only as wide as its label.
    const pill_width = renderer.pill_shape.width;
    try std.testing.expect(pill_width < @as(u32, plan.labels[1].width) * renderer.cell_width);
    const middle = renderer.pill.pixels[(@as(usize, renderer.key.?.height / 2) * pill_width + pill_width / 2) * 4 ..][0..4];
    try std.testing.expectEqual(@as(u8, 255), middle[3]);

    var storage: [kitty.transmission_budget_per_frame + 8192]u8 = undefined;
    var writer = Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expect(renderer.covers(&plan, palette));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Y=7") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, writer.buffered(), "a=p"));
    const generation = renderer.strip.generation;
    renderer.prepare(&plan, palette);
    writer = Io.Writer.fixed(&storage);
    try std.testing.expectEqual(@as(usize, 0), try renderer.write(&writer));
    try std.testing.expectEqual(generation, renderer.strip.generation);

    plan.area.x += 1;
    renderer.observe(&plan, palette);
    try std.testing.expect(renderer.retirementPending());
    writer = Io.Writer.fixed(&storage);
    _ = try renderer.writeRetirements(&writer);
    renderer.prepare(&plan, palette);
    writer = Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "a=t") == null);
    try std.testing.expect(renderer.covers(&plan, palette));
}

test "label coverage rejects stale focus text theme and cell size" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    var palette = theme.default_theme.palette;
    _ = renderer.configure(.{ .support = .supported, .cell_width = 10, .cell_height = 20 });
    var plan = testingPlan(&.{ "zsh", "nvim" }, 1);
    renderer.prepare(&plan, &palette);
    var storage: [128 * 1024]u8 = undefined;
    var writer = Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    const strip_generation = renderer.strip.generation;
    const pill_generation = renderer.pill.generation;
    plan.labels[0].selected = true;
    plan.labels[1].selected = false;
    try std.testing.expect(!renderer.covers(&plan, &palette));
    try std.testing.expect(renderer.coversText(&plan, &palette));
    renderer.observe(&plan, &palette);
    try std.testing.expect(!renderer.retirementPending());
    renderer.prepare(&plan, &palette);
    renderer.prepare(&plan, &palette);
    try std.testing.expect(!renderer.strip.image_dirty);
    try std.testing.expect(renderer.pill.image_dirty);
    try std.testing.expectEqual(strip_generation, renderer.strip.generation);
    try std.testing.expectEqual(pill_generation + 1, renderer.pill.generation);
    writer = Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expect(renderer.covers(&plan, &palette));

    plan = testingPlan(&.{ "zsh", "bash" }, 0);
    try std.testing.expect(!renderer.covers(&plan, &palette));
    try std.testing.expect(!renderer.coversText(&plan, &palette));
    renderer.prepare(&plan, &palette);
    try std.testing.expect(renderer.retirementPending());
    try std.testing.expect(!renderer.coversText(&plan, &palette));
    writer = Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    palette.subtext0 = .{ .rgb = .{ 12, 34, 56 } };
    try std.testing.expect(!renderer.coversText(&plan, &palette));
    renderer.prepare(&plan, &palette);
    try std.testing.expect(renderer.retirementPending());
    writer = Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expect(renderer.covers(&plan, &palette));
    try std.testing.expect(renderer.coversText(&plan, &palette));
    _ = renderer.configure(.{ .support = .supported, .cell_width = 12, .cell_height = 28 });
    try std.testing.expect(!renderer.covers(&plan, &palette));
    try std.testing.expect(!renderer.coversText(&plan, &palette));
    renderer.prepare(&plan, &palette);
    writer = Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expect(renderer.covers(&plan, &palette));
    _ = renderer.configure(.{ .support = .unsupported, .cell_width = 0, .cell_height = 0 });
    try std.testing.expect(!renderer.coversText(&plan, &palette));
    writer = Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "a=d,d=I") != null);
    try std.testing.expect(!renderer.damaged());
}

test "large label images are chunked and canceled before replacement or hide" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    const palette = &theme.default_theme.palette;
    _ = renderer.configure(.{ .support = .supported, .cell_width = 22, .cell_height = 64 });
    const names = [_][]const u8{"long-process-label"} ** 8;
    const large = testingPlan(&names, 3);
    renderer.prepare(&large, palette);
    try std.testing.expect(!renderer.failed);
    try std.testing.expect(renderer.retainedBytes() <= max_cache_bytes);
    var storage: [kitty.transmission_budget_per_frame + 8192]u8 = undefined;
    var writer = Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expect(renderer.transferInProgress());
    try std.testing.expect(!renderer.covers(&large, palette));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "a=p") == null);
    renderer.prepare(&large, palette);
    while (renderer.transferInProgress()) {
        writer = Io.Writer.fixed(&storage);
        _ = try renderer.write(&writer);
    }
    try std.testing.expect(renderer.covers(&large, palette));

    const replacement = testingPlan(&names, 4);
    renderer.prepare(&replacement, palette);
    writer = Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    while (renderer.transferInProgress()) {
        writer = Io.Writer.fixed(&storage);
        _ = try renderer.write(&writer);
    }
    try std.testing.expect(renderer.covers(&replacement, palette));

    const other = testingPlan(&names, 5);
    renderer.prepare(&other, palette);
    writer = Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    if (renderer.transferInProgress()) {
        renderer.prepare(&.{}, palette);
        try std.testing.expect(renderer.transferInProgress());
        writer = Io.Writer.fixed(&storage);
        _ = try renderer.write(&writer);
        try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "\x1b_Gm=0;\x1b\\"));
    } else {
        renderer.prepare(&.{}, palette);
        writer = Io.Writer.fixed(&storage);
        _ = try renderer.write(&writer);
    }
    try std.testing.expect(!renderer.transferInProgress());
    try std.testing.expect(!renderer.covers(&other, palette));
}

test "focus replacements transmit only the pill and keep the strip in place" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    const palette = &theme.default_theme.palette;
    _ = renderer.configure(.{ .support = .supported, .cell_width = 22, .cell_height = 64 });
    const names = [_][]const u8{"long-process-label"} ** 8;
    var plan = testingPlan(&names, 0);
    renderer.prepare(&plan, palette);
    var storage: [kitty.transmission_budget_per_frame + 8192]u8 = undefined;
    while (renderer.damaged()) {
        var writer = Io.Writer.fixed(&storage);
        _ = try renderer.write(&writer);
    }

    const strip_id = renderer.strip.emitted_image_id;
    const strip_key = renderer.key.?;
    const strip_pixels = renderer.strip.pixels.ptr;
    const strip_generation = renderer.strip.generation;
    for (1..4) |selected| {
        plan = testingPlan(&names, selected);
        renderer.observe(&plan, palette);
        try std.testing.expect(renderer.coversText(&plan, palette));
        try std.testing.expect(!renderer.covers(&plan, palette));
        try std.testing.expect(!renderer.retirementPending());
        renderer.prepare(&plan, palette);
        try std.testing.expectEqual(strip_key, renderer.key.?);
        try std.testing.expectEqual(strip_pixels, renderer.strip.pixels.ptr);
        try std.testing.expectEqual(strip_generation, renderer.strip.generation);
        try std.testing.expect(!renderer.strip.image_dirty);
        try std.testing.expect(renderer.pill.image_dirty);
        try std.testing.expect(renderer.coversText(&plan, palette));
        var writer = Io.Writer.fixed(&storage);
        _ = try renderer.write(&writer);
        // One small pill: transmitted, placed and the old pill deleted in one frame.
        try std.testing.expect(!renderer.transferInProgress());
        try std.testing.expectEqual(strip_id, renderer.strip.emitted_image_id);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, writer.buffered(), "a=t"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, writer.buffered(), "a=p"));
        const placed = std.mem.indexOf(u8, writer.buffered(), "a=p").?;
        const deleted = std.mem.indexOf(u8, writer.buffered(), "a=d,d=I").?;
        try std.testing.expect(placed < deleted);
        try std.testing.expect(renderer.covers(&plan, palette));
        try std.testing.expect(!renderer.damaged());
    }

    renderer.observe(&.{}, palette);
    try std.testing.expect(!renderer.coversText(&plan, palette));
    var writer = Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "a=d") != null);
    try std.testing.expect(!renderer.damaged());
}

test "unsupported text quotas and allocation failure keep the cell fallback" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var renderer = Renderer.init(failing.allocator());
    defer renderer.deinit();
    const palette = &theme.default_theme.palette;
    const plan = testingPlan(&.{ "zsh", "nvim" }, 1);
    _ = renderer.configure(.{ .support = .supported, .cell_width = 10, .cell_height = 20 });
    renderer.prepare(&plan, &theme.builtin(.terminal).palette);
    try std.testing.expectEqual(@as(usize, 0), renderer.retainedBytes());
    renderer.prepare(&plan, palette);
    try std.testing.expect(renderer.failed);
    try std.testing.expect(!renderer.covers(&plan, palette));
    try std.testing.expect(!renderer.coversText(&plan, palette));
    try std.testing.expect(!renderer.damaged());
    const generation = renderer.strip.generation;
    renderer.prepare(&plan, palette);
    try std.testing.expectEqual(generation, renderer.strip.generation);
    _ = renderer.configure(.{ .support = .supported, .cell_width = 1000, .cell_height = 256 });
    renderer.prepare(&plan, palette);
    try std.testing.expectEqual(@as(usize, 0), renderer.retainedBytes());

    var unsupported = Renderer.init(std.testing.allocator);
    defer unsupported.deinit();
    _ = unsupported.configure(.{ .support = .supported, .cell_width = 10, .cell_height = 20 });
    const unknown_glyph = testingPlan(&.{"\u{10ffff}"}, 0);
    unsupported.prepare(&unknown_glyph, palette);
    try std.testing.expect(unsupported.failed);
    try std.testing.expect(!unsupported.covers(&unknown_glyph, palette));
    try std.testing.expect(!unsupported.damaged());
}
