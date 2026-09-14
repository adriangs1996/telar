const std = @import("std");
const Canvas = @import("../widgets/Canvas.zig");
const GenericWidgetList = @import("../widgets/GenericWidgetList.zig").Type;
const CanvasFixture = @import("CanvasFixture.zig");
const Surface = @import("../widgets/Surface.zig");
const Text = @import("../widgets/Text.zig");
const Sprite = @import("../widgets/Sprite.zig");

const Widget = union(enum) {
    surface: Surface,
    text: Text,
    sprite: Sprite,

    pub fn draw(widget: Widget, canvas: *Canvas) !void {
        switch (widget) {
            inline else => |value| try value.draw(canvas),
        }
    }
};

test "widget lists own concrete values preserve painter order and reject overflow" {
    var fixture = try CanvasFixture.init();
    defer fixture.deinit();
    var canvas = fixture.canvas();
    const WidgetList = GenericWidgetList(Widget, 2);
    var list: WidgetList = .{};
    var background: Surface = .{ .bounds = .{ .x = 20, .y = 30, .width = 100, .height = 24 }, .fill = .{ .color = canvas.theme.palette.surface0, .radius = 4 } };
    try list.append(.{ .surface = background });
    try list.append(.{ .text = .{ .bounds = background.bounds, .label = .{ .text = "Widgets", .face = .sans, .size = .body } } });
    background.bounds.x = 500;
    try std.testing.expectError(error.WidgetCapacityExceeded, list.append(.{ .surface = background }));
    try list.draw(&canvas);
    const quads = fixture.quads.items();
    try std.testing.expect(quads.len > 1);
    try std.testing.expectEqual(@as(f32, 20), quads[0].x);
    try std.testing.expectEqual(@as(f32, 100), quads[0].width);
    for (quads[1..]) |quad| {
        try std.testing.expect(quad.x >= 20 and quad.x + quad.width <= 120);
    }
}

test "warm widget drawing uses the supplied canvas without allocations" {
    var fixture = try CanvasFixture.init();
    defer fixture.deinit();
    var canvas = fixture.canvas();
    const WidgetList = GenericWidgetList(Widget, 2);
    var list: WidgetList = .{};
    const bounds: @import("../render/Rect.zig") = .{ .x = 0, .y = 0, .width = 100, .height = 24 };
    try list.append(.{ .surface = .{ .bounds = bounds, .fill = .{ .color = canvas.theme.palette.surface0, .radius = 4 } } });
    try list.append(.{ .text = .{ .bounds = bounds, .label = .{ .text = "Warm", .face = .sans, .size = .body } } });
    try list.draw(&canvas);
    const shape_calls = fixture.atlas.shape_calls;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    fixture.atlas.allocator = failing.allocator();
    fixture.quads.allocator = failing.allocator();
    defer fixture.atlas.allocator = std.testing.allocator;
    defer fixture.quads.allocator = std.testing.allocator;
    fixture.quads.clear();
    try list.draw(&canvas);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(shape_calls, fixture.atlas.shape_calls);
}

test "sprite widgets keep page selection tint and placement inside a composed list" {
    var fixture = try CanvasFixture.init();
    defer fixture.deinit();
    var page = try @import("../image/SpritePage.zig").init(std.testing.allocator, 16);
    defer page.deinit();
    var canvas = fixture.canvas();
    canvas.sprites = &page;
    const mark = canvas.providerMark(.codex).?;
    const WidgetList = GenericWidgetList(Widget, 2);
    var list: WidgetList = .{};
    try list.append(.{ .surface = .{ .bounds = .{ .x = 10, .y = 20, .width = 50, .height = 50 }, .fill = .{ .color = canvas.theme.palette.surface0, .radius = 4 } } });
    try list.append(.{ .sprite = .{ .bounds = .{ .x = 12.5, .y = 24.75, .width = 16, .height = 16 }, .paint = .{ .sprite = mark, .alpha = 0.5 } } });
    try list.draw(&canvas);
    const quads = fixture.quads.items();
    try std.testing.expectEqual(@as(usize, 2), quads.len);
    try std.testing.expectEqual(@import("../render/Quad.zig").atlas_texture, quads[0].texture);
    const sprite = quads[1];
    try std.testing.expectEqual(@import("../render/Quad.zig").sprite_texture, sprite.texture);
    try std.testing.expectEqual(@as(f32, 12), sprite.x);
    try std.testing.expectEqual(@as(f32, 24), sprite.y);
    try std.testing.expectEqual(@as(f32, 0.5), sprite.a);
    try std.testing.expectEqualSlices(f32, &page.uv(mark), &.{ sprite.u0, sprite.v0, sprite.u1, sprite.v1 });
    canvas.sprites = null;
    fixture.quads.clear();
    try list.draw(&canvas);
    try std.testing.expectEqual(@as(usize, 1), fixture.quads.items().len);
}
