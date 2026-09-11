//! Small JetBrains Mono labels and the selected pill inside the pane border.
//! Client-owned media: one <=1 MiB RGBA buffer, two bounded host image slots.
//! Focus replacements keep the old labels visible until the new image is placed.
//! Text, geometry and theme changes still fall back to cells; latest plan wins.

const PlanType = @import("../presentation/Plan.zig");
const LabelType = @import("../presentation/Label.zig");
const std = @import("std");
const measure_module = @import("telar-core").measure;
const PillRenderer = @import("PillRenderer.zig");
const theme = @import("../ui/theme_support.zig");
const kitty_codec = @import("kitty_codec.zig");

pub const max_cache_bytes = 1024 * 1024;
pub const image_id: u32 = 0x80003000;
pub const placement_id: u32 = 0x80003100;

fn testingPlan(names: []const []const u8, selected: usize) PlanType {
    var plan: PlanType = .{ .area = .{ .x = 2, .y = 1, .h = 1 } };
    for (names, 0..) |name, index| {
        var label: LabelType = .{ .offset = plan.area.w, .width = 0, .selected = index == selected };
        const text = std.fmt.bufPrint(&label.bytes, "{d} {s}", .{ index + 1, name }) catch unreachable;
        label.len = @intCast(text.len);
        label.width = measure_module(text) + 2;
        plan.labels[plan.len] = label;
        plan.len += 1;
        plan.area.w += label.width + @as(u16, @intFromBool(index + 1 != names.len));
    }

    return plan;
}

test "small labels use JetBrains Mono and a centered three-quarter-height pill" {
    var renderer = PillRenderer.init(std.testing.allocator);
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
    var storage: [kitty_codec.transmission_budget_per_frame + 8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expect(renderer.covers(&plan, palette));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Y=7") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, writer.buffered(), "a=p"));
    const generation = renderer.generation;
    renderer.prepare(&plan, palette);
    writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectEqual(@as(usize, 0), try renderer.write(&writer));
    try std.testing.expectEqual(generation, renderer.generation);

    plan.area.x += 1;
    renderer.observe(&plan, palette);
    try std.testing.expect(renderer.retirementPending());
    writer = std.Io.Writer.fixed(&storage);
    _ = try renderer.writeRetirements(&writer);
    renderer.prepare(&plan, palette);
    writer = std.Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "a=t") == null);
    try std.testing.expect(renderer.covers(&plan, palette));
}

test "a position-only move settles after one placement instead of retiring every pass" {
    var renderer = PillRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    const palette = &theme.default_theme.palette;
    _ = renderer.configure(.{ .support = .supported, .cell_width = 10, .cell_height = 20 });
    var plan = testingPlan(&.{ "zsh", "nvim" }, 1);
    renderer.prepare(&plan, palette);
    var storage: [128 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expect(!renderer.damaged());

    // The sidebar grew: same text and focus, the strip only shifted right.
    plan.area.x += 6;
    renderer.observe(&plan, palette);
    renderer.prepare(&plan, palette);
    writer = std.Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, writer.buffered(), "a=p"));
    try std.testing.expect(renderer.covers(&plan, palette));
    try std.testing.expect(!renderer.retirementPending());
    try std.testing.expect(!renderer.damaged());

    renderer.observe(&plan, palette);
    renderer.prepare(&plan, palette);
    writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectEqual(@as(usize, 0), try renderer.write(&writer));
    try std.testing.expect(renderer.covers(&plan, palette));
}

test "label coverage rejects stale focus text theme and cell size" {
    var renderer = PillRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    var palette = theme.default_theme.palette;
    _ = renderer.configure(.{ .support = .supported, .cell_width = 10, .cell_height = 20 });
    var plan = testingPlan(&.{ "zsh", "nvim" }, 1);
    renderer.prepare(&plan, &palette);
    var storage: [128 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    const generation = renderer.generation;
    plan.labels[0].selected = true;
    plan.labels[1].selected = false;
    try std.testing.expect(!renderer.covers(&plan, &palette));
    try std.testing.expect(renderer.coversText(&plan, &palette));
    renderer.observe(&plan, &palette);
    try std.testing.expect(!renderer.retirementPending());
    renderer.prepare(&plan, &palette);
    renderer.prepare(&plan, &palette);
    try std.testing.expect(renderer.image_dirty);
    try std.testing.expectEqual(generation + 1, renderer.generation);
    writer = std.Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);

    plan = testingPlan(&.{ "zsh", "bash" }, 0);
    try std.testing.expect(!renderer.covers(&plan, &palette));
    try std.testing.expect(!renderer.coversText(&plan, &palette));
    renderer.prepare(&plan, &palette);
    try std.testing.expect(renderer.retirementPending());
    try std.testing.expect(!renderer.coversText(&plan, &palette));
    writer = std.Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    palette.subtext0 = .{ .rgb = .{ 12, 34, 56 } };
    try std.testing.expect(!renderer.coversText(&plan, &palette));
    renderer.prepare(&plan, &palette);
    try std.testing.expect(renderer.retirementPending());
    writer = std.Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expect(renderer.covers(&plan, &palette));
    try std.testing.expect(renderer.coversText(&plan, &palette));
    _ = renderer.configure(.{ .support = .supported, .cell_width = 12, .cell_height = 28 });
    try std.testing.expect(!renderer.covers(&plan, &palette));
    try std.testing.expect(!renderer.coversText(&plan, &palette));
    renderer.prepare(&plan, &palette);
    writer = std.Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expect(renderer.covers(&plan, &palette));
    _ = renderer.configure(.{ .support = .unsupported, .cell_width = 0, .cell_height = 0 });
    try std.testing.expect(!renderer.coversText(&plan, &palette));
    writer = std.Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "a=d,d=I") != null);
    try std.testing.expect(!renderer.damaged());
}

test "large label images are chunked and canceled before replacement or hide" {
    var renderer = PillRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    const palette = &theme.default_theme.palette;
    _ = renderer.configure(.{ .support = .supported, .cell_width = 22, .cell_height = 64 });
    const names = [_][]const u8{"long-process-label"} ** 8;
    const large = testingPlan(&names, 3);
    renderer.prepare(&large, palette);
    try std.testing.expect(!renderer.failed);
    try std.testing.expect(renderer.retainedBytes() <= max_cache_bytes);
    var storage: [kitty_codec.transmission_budget_per_frame + 8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expect(renderer.transferInProgress());
    try std.testing.expect(!renderer.covers(&large, palette));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "a=p") == null);
    renderer.prepare(&large, palette);
    while (renderer.transferInProgress()) {
        writer = std.Io.Writer.fixed(&storage);
        _ = try renderer.write(&writer);
        try std.testing.expect(writer.buffered().len <= storage.len);
    }

    try std.testing.expect(renderer.covers(&large, palette));
    var replaced = large;
    replaced.labels[3].selected = false;
    replaced.labels[4].selected = true;
    renderer.prepare(&replaced, palette);
    writer = std.Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expect(renderer.transferInProgress());
    const small = testingPlan(&.{"nvim"}, 0);
    renderer.observe(&small, palette);
    try std.testing.expect(renderer.abort_pending);
    writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectEqual(@as(usize, 0), try renderer.writeRetirements(&writer));
    renderer.prepare(&small, palette);
    writer = std.Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "\x1b_Gm=0;\x1b\\"));
    try std.testing.expect(renderer.covers(&small, palette));

    renderer.prepare(&large, palette);
    writer = std.Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    renderer.observe(&.{}, palette);
    writer = std.Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "\x1b_Gm=0;\x1b\\"));
    try std.testing.expect(!renderer.damaged());
}

test "focus replacements retain graphical text through chunking and latest-wins cancellation" {
    var renderer = PillRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    const palette = &theme.default_theme.palette;
    _ = renderer.configure(.{ .support = .supported, .cell_width = 22, .cell_height = 64 });
    const names = [_][]const u8{"long-process-label"} ** 8;
    var plan = testingPlan(&names, 0);
    renderer.prepare(&plan, palette);
    var storage: [kitty_codec.transmission_budget_per_frame + 8192]u8 = undefined;
    while (renderer.damaged()) {
        var writer = std.Io.Writer.fixed(&storage);
        _ = try renderer.write(&writer);
    }

    const original_id = renderer.emitted_image_id;
    const original_key = renderer.key.?;
    const original_pixels = renderer.pixels.ptr;
    for (1..4) |selected| {
        plan = testingPlan(&names, selected);
        renderer.observe(&plan, palette);
        try std.testing.expect(renderer.coversText(&plan, palette));
        try std.testing.expect(!renderer.covers(&plan, palette));
        try std.testing.expect(!renderer.retirementPending());
        renderer.prepare(&plan, palette);
        try std.testing.expectEqual(original_key, renderer.key.?);
        try std.testing.expectEqual(original_pixels, renderer.pixels.ptr);
        try std.testing.expect(renderer.coversText(&plan, palette));
        var writer = std.Io.Writer.fixed(&storage);
        _ = try renderer.write(&writer);
        try std.testing.expect(renderer.transferInProgress());
        try std.testing.expect(renderer.coversText(&plan, palette));
        try std.testing.expectEqual(original_id, renderer.emitted_image_id);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "a=d") == null);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "a=p") == null);
        if (selected > 1) {
            try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "\x1b_Gm=0;\x1b\\"));
        }
    }

    while (renderer.transferInProgress()) {
        var writer = std.Io.Writer.fixed(&storage);
        _ = try renderer.write(&writer);
        try std.testing.expect(renderer.coversText(&plan, palette));
        if (renderer.transferInProgress()) {
            try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "a=d") == null);
            try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "a=p") == null);
        } else {
            const placed = std.mem.indexOf(u8, writer.buffered(), "a=p").?;
            const deleted = std.mem.indexOf(u8, writer.buffered(), "a=d,d=I").?;
            try std.testing.expect(placed < deleted);
        }
    }

    try std.testing.expectEqual(original_id ^ 1, renderer.emitted_image_id);
    try std.testing.expect(renderer.covers(&plan, palette));
    try std.testing.expect(!renderer.damaged());
    renderer.observe(&.{}, palette);
    try std.testing.expect(!renderer.coversText(&plan, palette));
    var writer = std.Io.Writer.fixed(&storage);
    _ = try renderer.write(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "a=d") != null);
    try std.testing.expect(!renderer.damaged());
}

test "unsupported text quotas and allocation failure keep the cell fallback" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var renderer = PillRenderer.init(failing.allocator());
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
    const generation = renderer.generation;
    renderer.prepare(&plan, palette);
    try std.testing.expectEqual(generation, renderer.generation);
    _ = renderer.configure(.{ .support = .supported, .cell_width = 1000, .cell_height = 256 });
    renderer.prepare(&plan, palette);
    try std.testing.expectEqual(@as(usize, 0), renderer.retainedBytes());

    var unsupported = PillRenderer.init(std.testing.allocator);
    defer unsupported.deinit();
    _ = unsupported.configure(.{ .support = .supported, .cell_width = 10, .cell_height = 20 });
    const unknown_glyph = testingPlan(&.{"\u{10ffff}"}, 0);
    unsupported.prepare(&unknown_glyph, palette);
    try std.testing.expect(unsupported.failed);
    try std.testing.expect(!unsupported.covers(&unknown_glyph, palette));
    try std.testing.expect(!unsupported.damaged());
}
