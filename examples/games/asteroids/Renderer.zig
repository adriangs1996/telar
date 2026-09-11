const Frame = @import("Frame.zig");
const std = @import("std");
const Game = @import("Game.zig");
const Colors = @import("Colors.zig");
const Pixel = @import("Pixel.zig");
const Renderer = @This();

frame: Frame,

pub fn deinit(self: *Renderer, allocator: std.mem.Allocator) void {
    self.frame.deinit(allocator);
}

pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Renderer {
    const frame = try Frame.init(allocator, width, height);
    return Renderer{
        .frame = frame,
    };
}

/// Renders the game state using KGP graphics so it can
/// be run in a terminal compatible with KGP.
///
/// @params:
///     game: The game state to render.
///
/// @returns: void
pub fn render(self: *Renderer, game: *const Game) void {
    self.frame.clear(Colors.black);

    const x: i32 = @intFromFloat(game.ship.position.x);
    const y: i32 = @intFromFloat(game.ship.position.y);
    self.frame.setPixel(Pixel.at(x, y, Colors.white));
}
