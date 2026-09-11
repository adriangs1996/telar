const std = @import("std");

const Vec2 = @import("Vec2.zig");

pub const Turn = enum {
    left,
    right,
    none,
};

const Input = @import("Input.zig");

const Bounds = @import("Bounds.zig");

const Ship = @import("Ship.zig");

const Game = @import("Game.zig");

const Color = @import("Color.zig");

const Colors = @import("Colors.zig");

const Pixel = @import("Pixel.zig");

const Frame = @import("Frame.zig");

const Renderer = @import("Renderer.zig");

pub fn main(init: std.process.Init) !void {
    const width: usize = 160;
    const height: usize = 90;
    var renderer = try Renderer.init(init.gpa, width, height);
    defer renderer.deinit(init.gpa);

    const game = Game.init(.{
        .width = @floatFromInt(width),
        .height = @floatFromInt(height),
    });
    renderer.render(&game);
}

test "a 2 x 2 Frame has 16 bytes" {
    const allocator = std.testing.allocator;
    const frame = try Frame.init(allocator, 2, 2);
    defer frame.deinit(allocator);

    try std.testing.expect(frame.pixels.len == 16);
}

test "setPixel 1, 1, red modifies last 4 bytes of a 2 x 2 Frame" {
    const allocator = std.testing.allocator;
    var frame = try Frame.init(allocator, 2, 2);
    defer frame.deinit(allocator);

    frame.setPixel(Pixel.at(1, 1, Colors.red));

    try std.testing.expect(frame.pixels[12] == Colors.red.r);
    try std.testing.expect(frame.pixels[13] == Colors.red.g);
    try std.testing.expect(frame.pixels[14] == Colors.red.b);
    try std.testing.expect(frame.pixels[15] == Colors.red.a);
}

test "negative coordinates or out of the frame does not modify the frame" {
    const allocator = std.testing.allocator;
    var frame = try Frame.init(allocator, 2, 2);
    defer frame.deinit(allocator);

    @memset(frame.pixels, 0);

    frame.setPixel(Pixel.at(-1, -1, Colors.red));
    frame.setPixel(Pixel.at(2, 2, Colors.red));

    for (frame.pixels) |pixel| {
        try std.testing.expect(pixel == 0);
    }
}
