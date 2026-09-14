//! Slice 7 of the GUI visual language: three chrome text sizes derived from
//! the terminal size, scaled by `gui.chrome.scale`, shaped side by side in
//! one atlas without touching the cell grid.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Fixture = @import("CanvasFixture.zig");
const Renderer = @import("../render/TerminalRenderer.zig");
const ChromeMetrics = @import("../widgets/ChromeMetrics.zig");
const CardGeometry = @import("../widgets/CardGeometry.zig");
const Canvas = @import("../widgets/Canvas.zig");
const Label = @import("../widgets/Label.zig");
const Size = @import("../widgets/label_size.zig").Size;
const Quad = @import("../render/Quad.zig").Quad;

const roles = [_]Size{ .terminal, .title, .body, .small };

test {
    _ = @import("../widgets/label_size.zig");
}

test "a label measures narrower at small than at title and paints in its own line box" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var canvas = fixture.canvas();
    const text = "fix proxy tests";
    const title = try canvas.measure(.{ .text = text, .face = .sans, .size = .title });
    const body = try canvas.measure(.{ .text = text, .face = .sans, .size = .body });
    const small = try canvas.measure(.{ .text = text, .face = .sans, .size = .small });
    try std.testing.expect(small < body);
    try std.testing.expectEqual(body, title);
    try std.testing.expect(title < try canvas.measure(.{ .text = text, .face = .sans }));
    // Monospace labels ignore the role: they are the terminal grid.
    try std.testing.expectEqual(try canvas.measure(.{ .text = text }), try canvas.measure(.{ .text = text, .size = .small }));

    // A small label in a tall row sits on one baseline centred in the row,
    // not on the terminal cell's baseline, and its glyphs are shorter.
    const row: @import("../render/Rect.zig") = .{ .x = 10, .y = 100, .width = 300, .height = 40 };
    _ = try canvas.textAt(row, .{ .text = "Hg", .face = .sans, .size = .small });
    const small_quads = try std.testing.allocator.dupe(Quad, fixture.quads.items());
    defer std.testing.allocator.free(small_quads);
    fixture.quads.clear();
    _ = try canvas.textAt(row, .{ .text = "Hg", .face = .sans, .size = .title });
    const title_quads = fixture.quads.items();
    try std.testing.expectEqual(@as(usize, 2), small_quads.len);
    try std.testing.expectEqual(@as(usize, 2), title_quads.len);
    try std.testing.expect(small_quads[0].height < title_quads[0].height);
    const small_box = try fixture.atlas.lineBox(.sans, canvas.chrome.small);
    const title_box = try fixture.atlas.lineBox(.sans, canvas.chrome.title);
    try std.testing.expect(small_box.height < title_box.height);
    const small_top = @floor(row.y + (row.height - small_box.height) / 2);
    const title_top = @floor(row.y + (row.height - title_box.height) / 2);
    try std.testing.expect(small_quads[0].y >= small_top and small_quads[0].y + small_quads[0].height <= small_top + small_box.height + 0.001);
    try std.testing.expect(title_quads[0].y >= title_top and title_quads[0].y + title_quads[0].height <= title_top + title_box.height + 0.001);
}

test "a frame with the three roles repaints warm with zero shaping and zero allocation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var canvas = fixture.canvas();
    const labels = [_][]const u8{ "telar", "fix proxy tests", "3m", "\u{26a0}", "\u{f07b} agents" };
    for (labels) |label| {
        for (roles) |size| {
            for (0..2) |bold| {
                try canvas.text(.{ .x = 0, .y = 0, .w = 60, .h = 1 }, .{ .text = label, .face = .sans, .size = size, .bold = bold == 1 });
            }
        }
    }

    const version = fixture.atlas.version;
    const calls = fixture.atlas.shape_calls;
    const rasters = fixture.atlas.raster_attempts;
    const count = fixture.quads.items().len;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    fixture.atlas.allocator = failing.allocator();
    fixture.quads.allocator = failing.allocator();
    defer fixture.atlas.allocator = std.testing.allocator;
    defer fixture.quads.allocator = std.testing.allocator;
    for (0..60) |_| {
        fixture.quads.clear();
        for (labels) |label| {
            for (roles) |size| {
                for (0..2) |bold| {
                    try canvas.text(.{ .x = 0, .y = 0, .w = 60, .h = 1 }, .{ .text = label, .face = .sans, .size = size, .bold = bold == 1 });
                    _ = try canvas.measure(.{ .text = label, .face = .sans, .size = size, .bold = bold == 1 });
                }
            }
        }
    }

    try std.testing.expectEqual(count, fixture.quads.items().len);
    try std.testing.expectEqual(version, fixture.atlas.version);
    try std.testing.expectEqual(calls, fixture.atlas.shape_calls);
    try std.testing.expectEqual(rasters, fixture.atlas.raster_attempts);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "the chrome scale enlarges chrome labels and cards but not the PTY grid" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    for ([_]f32{ 1, 2 }) |scale| {
        renderer.config.chrome = .{};
        const base_size = try renderer.measure(.{ .width = 1000, .height = 700, .scale = scale });
        const base = renderer.chrome;
        const base_card = CardGeometry.derive(base, renderer.metrics);
        var quads = @import("../render/QuadList.zig").init(std.testing.allocator);
        defer quads.deinit();
        var canvas: Canvas = .{ .atlas = &renderer.atlas.?, .quads = &quads, .metrics = renderer.metrics, .origin = renderer.origin, .theme = client.theme_support.default_theme, .chrome = base, .viewport = renderer.viewport };
        const base_width = try canvas.measure(.{ .text = "agents", .face = .sans, .size = .body });

        renderer.config.chrome = .{ .scale = 1.5 };
        const larger_size = try renderer.measure(.{ .width = 1000, .height = 700, .scale = scale });
        const larger = renderer.chrome;
        try std.testing.expectEqual(base_size, larger_size);
        try std.testing.expectEqual(base.vertical(), larger.vertical());
        try std.testing.expectEqual(base.pane_header, larger.pane_header);
        try std.testing.expectEqual(renderer.metrics.pixel_height, @as(u16, @intFromFloat(15 * scale)));
        try std.testing.expect(larger.title > base.title);
        try std.testing.expect(larger.body > base.body);
        try std.testing.expect(larger.small > base.small);
        try std.testing.expect(CardGeometry.derive(larger, renderer.metrics).height() > base_card.height());
        canvas.chrome = larger;
        try std.testing.expect(try canvas.measure(.{ .text = "agents", .face = .sans, .size = .body }) > base_width);

        // The body line box measured by FreeType fits the pane header at
        // every chrome scale, which is what the 1.3 em cap promises.
        for ([_]f32{ 1, 1.5, 2 }) |factor| {
            const chrome = ChromeMetrics.resolve(.{ .chrome = .{ .scale = factor } }, scale);
            const box = try renderer.atlas.?.lineBox(.sans_semibold, chrome.body);
            try std.testing.expect(box.height <= @as(f32, @floatFromInt(chrome.pane_header)));
        }
    }
}
