//! Small JetBrains Mono labels and the selected pill inside the pane border.
//! Client-owned media: one <=1 MiB RGBA image, one placement, latest plan wins.
//! Cells remain visible until the exact label snapshot has reached the host.

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
const image_id: u32 = 0x80003000;
const placement_id: u32 = 0x80003100;

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

pub const Renderer = struct {
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
    desired: ?ui.Rect = null,
    emitted: ?ui.Rect = null,
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
            std.meta.eql(renderer.desired, @as(?ui.Rect, plan.area)) and
            std.meta.eql(renderer.emitted, @as(?ui.Rect, plan.area));
    }

    /// Retires stale text before the next cell frame, without rasterization.
    /// Example: `renderer.observe(plan, palette);`.
    pub fn observe(renderer: *Renderer, plan: *const labels.Plan, palette: *const theme.Palette) void {
        const key = renderer.renderKey(plan, palette) orelse {
            renderer.hide();
            return;
        };
        if (!renderer.matches(plan, key) or !std.meta.eql(renderer.desired, @as(?ui.Rect, plan.area))) {
            renderer.hide();
        }
    }

    pub fn transferInProgress(renderer: *const Renderer) bool {
        return renderer.abort_pending or renderer.transfer_offset != 0;
    }

    pub fn retirementPending(renderer: *const Renderer) bool {
        return renderer.emitted != null and
            (renderer.image_dirty or !std.meta.eql(renderer.desired, renderer.emitted));
    }

    /// Deletes stale placements only when no continuation is open.
    /// Example: `_ = try renderer.writeRetirements(writer);`.
    pub fn writeRetirements(renderer: *Renderer, writer: *Io.Writer) Io.Writer.Error!usize {
        if (!renderer.retirementPending() or renderer.transferInProgress()) {
            return 0;
        }

        const written = try kitty.writeDeletePlacement(writer, image_id, placement_id);
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
    pub fn write(renderer: *Renderer, writer: *Io.Writer) Io.Writer.Error!usize {
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
            written += try kitty.writeDeleteImage(writer, image_id);
            renderer.image_emitted = false;
        }

        const area = renderer.desired orelse return written;
        const key = renderer.key orelse return written;
        if (renderer.image_dirty) {
            const progress = try kitty.writeTransmissionChunks(writer, .{
                .external_id = image_id,
                .image = .{
                    .key = .{ .image_id = image_id, .generation = 1 },
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
            renderer.image_emitted = true;
            renderer.image_dirty = false;
        }

        written += try kitty.writePlacement(writer, .{
            .image_id = image_id,
            .placement_id = placement_id,
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
        renderer.emitted = area;
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
};

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

    // Inactive glyphs have straight-alpha text RGB, not a preblended dark edge.
    var text_pixels: usize = 0;
    const width = renderer.key.?.width;
    for (0..renderer.key.?.height) |y| {
        for (0..@as(usize, plan.labels[0].width) * renderer.cell_width) |x| {
            const pixel = renderer.pixels[(y * width + x) * 4 ..][0..4];
            if (pixel[3] != 0) {
                try std.testing.expectEqualSlices(u8, &palette.subtext0.rgb, pixel[0..3]);
                text_pixels += 1;
            }
        }
    }

    try std.testing.expect(text_pixels != 0);
    var storage: [kitty.transmission_budget_per_frame + 8192]u8 = undefined;
    var writer = Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expect(renderer.covers(&plan, palette));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Y=7") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, writer.buffered(), "a=p"));
    const generation = renderer.generation;
    renderer.prepare(&plan, palette);
    writer = Io.Writer.fixed(&storage);
    try std.testing.expectEqual(@as(usize, 0), try renderer.write(&writer));
    try std.testing.expectEqual(generation, renderer.generation);

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
    const generation = renderer.generation;
    plan.labels[0].selected = true;
    plan.labels[1].selected = false;
    try std.testing.expect(!renderer.covers(&plan, &palette));
    renderer.observe(&plan, &palette);
    renderer.prepare(&plan, &palette);
    renderer.prepare(&plan, &palette);
    try std.testing.expect(renderer.image_dirty);
    try std.testing.expectEqual(generation + 1, renderer.generation);
    writer = Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);

    plan = testingPlan(&.{ "zsh", "bash" }, 0);
    try std.testing.expect(!renderer.covers(&plan, &palette));
    renderer.prepare(&plan, &palette);
    palette.subtext0 = .{ .rgb = .{ 12, 34, 56 } };
    renderer.prepare(&plan, &palette);
    writer = Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expect(renderer.covers(&plan, &palette));
    _ = renderer.configure(.{ .support = .supported, .cell_width = 12, .cell_height = 28 });
    try std.testing.expect(!renderer.covers(&plan, &palette));
    renderer.prepare(&plan, &palette);
    writer = Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expect(renderer.covers(&plan, &palette));
    _ = renderer.configure(.{ .support = .unsupported, .cell_width = 0, .cell_height = 0 });
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
        try std.testing.expect(writer.buffered().len <= storage.len);
    }

    try std.testing.expect(renderer.covers(&large, palette));
    var replaced = large;
    replaced.labels[3].selected = false;
    replaced.labels[4].selected = true;
    renderer.prepare(&replaced, palette);
    writer = Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expect(renderer.transferInProgress());
    const small = testingPlan(&.{"nvim"}, 0);
    renderer.observe(&small, palette);
    try std.testing.expect(renderer.abort_pending);
    writer = Io.Writer.fixed(&storage);
    try std.testing.expectEqual(@as(usize, 0), try renderer.writeRetirements(&writer));
    renderer.prepare(&small, palette);
    writer = Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "\x1b_Gm=0;\x1b\\"));
    try std.testing.expect(renderer.covers(&small, palette));

    renderer.prepare(&large, palette);
    writer = Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    renderer.observe(&.{}, palette);
    writer = Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "\x1b_Gm=0;\x1b\\"));
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
    try std.testing.expect(!renderer.damaged());
    const generation = renderer.generation;
    renderer.prepare(&plan, palette);
    try std.testing.expectEqual(generation, renderer.generation);
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
