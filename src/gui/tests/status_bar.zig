const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Fixture = @import("ChromeFixture.zig");
const Rect = @import("../render/Rect.zig");
const Color = @import("../render/Color.zig");
const colors = @import("../render/cell_colors.zig");

test "native bottom widgets preserve configured positions and legacy top content" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var state: client.State = .{};
    const red = core.Color{ .rgb = .{ 255, 0, 0 } };
    const green = core.Color{ .rgb = .{ 0, 255, 0 } };
    const blue = core.Color{ .rgb = .{ 0, 0, 255 } };
    state.layout.bottom = .{ try colored("left", red), .tabs, try colored("right", green) };
    state.layout.top_right = try colored("legacy", blue);
    var projection = fixture.projection();
    projection.bar_state = &state;
    try fixture.paint(projection);
    const left = paintedBounds(&fixture, red).?;
    const right = paintedBounds(&fixture, green).?;
    const legacy = paintedBounds(&fixture, blue).?;
    const margin = fixture.session.renderer.chrome.px(8);
    try std.testing.expectEqual(margin, left.x);
    try std.testing.expect(left.x + left.width <= right.x);
    try std.testing.expect(right.x + right.width <= legacy.x);
    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(fixture.session.renderer.viewport[0])) - margin, legacy.x + legacy.width, 1);

    state.layout.bottom = .{ try colored("left", red), try colored("center", green), .tabs };
    try fixture.paint(projection);
    const center = paintedBounds(&fixture, green).?;
    try std.testing.expect(center.x < right.x);
    try std.testing.expect(center.x > left.x + left.width);
}

test "native footer reserves TLS ahead of widgets and mode hints in narrow windows" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.showSidebar(false);
    const tls_color = core.Color{ .rgb = .{ 243, 41, 99 } };
    fixture.session.gui.theme.palette.peach = tls_color;
    fixture.session.gui.theme.palette.yellow = tls_color;
    fixture.session.gui.theme.palette.red = tls_color;
    const widget_color = core.Color{ .rgb = .{ 0, 255, 0 } };
    var state: client.State = .{};
    state.layout.bottom = .{ try colored("left widget that exceeds the viewport", widget_color), .tabs, try colored("right widget that exceeds the viewport", widget_color) };
    state.layout.top_right = try colored("legacy widget that exceeds the viewport", widget_color);
    var hints: client.Hints = .{};
    hints.append(.{ .key = try client.parseKey("Ctrl+v"), .label = "split vertically" });
    for ([_]u16{ 120, 32, 12 }) |width| {
        try fixture.resize(width, 8);
        var projection = fixture.projection();
        projection.bar_state = &state;
        for ([_]bool{ true, false }) |active| {
            projection.proxy_tls_active = active;
            projection.proxy_system_trusted = !active;
            for (0..3) |mode| {
                projection.status_mode = switch (mode) {
                    0 => .normal,
                    1 => .copy,
                    else => .{ .prefix = hints },
                };
                try fixture.paint(projection);
                const tls = paintedBounds(&fixture, tls_color).?;
                const renderer = &fixture.session.renderer;
                const right_edge: f32 = @floatFromInt(renderer.viewport[0]);
                try std.testing.expect(tls.x > right_edge - 8 * @as(f32, @floatFromInt(renderer.metrics.cell_width)));
                try std.testing.expect(tls.x + tls.width <= right_edge);
                if (mode == 0) {
                    const widgets = paintedBounds(&fixture, widget_color).?;
                    try std.testing.expect(widgets.x + widgets.width <= tls.x);
                } else {
                    try std.testing.expect(paintedBounds(&fixture, widget_color) == null);
                }
            }
        }
    }
}

test "native footer clips tall terminal line spacing without hiding configured widgets" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.session.renderer.config.font.line_height = 3;
    try fixture.measure(.{ .width = 1200, .height = 800, .scale = 2 });
    const renderer = &fixture.session.renderer;
    try std.testing.expect(renderer.metrics.cell_height > renderer.chrome.status_bar);
    const color = core.Color{ .rgb = .{ 0, 255, 0 } };
    var state: client.State = .{};
    state.layout.bottom = .{ try colored("visible", color), .empty, .tabs };
    state.layout.top_right = try colored("legacy", color);
    var projection = fixture.projection();
    projection.bar_state = &state;
    try fixture.paint(projection);
    const widgets = paintedBounds(&fixture, color).?;
    const band = fixture.chrome.presented().bands.status_bar;
    try std.testing.expectEqual(band.y, widgets.y);
    try std.testing.expectEqual(band.height, widgets.height);
    for (renderer.quads.items()) |quad| {
        if (quad.r == 0 and quad.g == 1 and quad.b == 0) {
            try std.testing.expect(quad.y >= band.y);
            try std.testing.expect(quad.y + quad.height <= band.y + band.height);
        }
    }
}

fn colored(text: []const u8, color: core.Color) !client.Slot {
    var content: client.Content = .{};
    try content.append(.{ .text = text, .style = .{ .background = .{ .value = color } } });
    return .{ .content = content };
}

fn paintedBounds(fixture: *Fixture, color: core.Color) ?Rect {
    const expected = colors.resolve(color, Color.black);
    const band = fixture.chrome.presented().bands.status_bar;
    var result: ?Rect = null;
    for (fixture.session.renderer.quads.items()) |quad| {
        if (quad.y < band.y or quad.r != expected.r or quad.g != expected.g or quad.b != expected.b) {
            continue;
        }

        if (result) |*bounds| {
            const end = @max(bounds.x + bounds.width, quad.x + quad.width);
            const bottom = @max(bounds.y + bounds.height, quad.y + quad.height);
            bounds.x = @min(bounds.x, quad.x);
            bounds.y = @min(bounds.y, quad.y);
            bounds.width = end - bounds.x;
            bounds.height = bottom - bounds.y;
        } else {
            result = .{ .x = quad.x, .y = quad.y, .width = quad.width, .height = quad.height };
        }
    }

    return result;
}
