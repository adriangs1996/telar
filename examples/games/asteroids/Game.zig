const Game = @This();
const Bounds = @import("Bounds.zig");
const Ship = @import("Ship.zig");
const Vec2 = @import("Vec2.zig");
const Input = @import("Input.zig");
bounds: Bounds,
ship: Ship,

pub fn init(bounds: Bounds) Game {
    return Game{
        .bounds = bounds,
        .ship = Ship{
            .position = Vec2{
                .x = bounds.width / 2,
                .y = bounds.height / 2,
            },
            .heading = 0.0,
            .velocity = Vec2{
                .x = 0.0,
                .y = 0.0,
            },
        },
    };
}

/// A tick of the game, updating game state based on the input.
///
/// @params:
///      input: The global input state, this includes keyboard, mouse, and other events.
///      dt: The time delta since the last tick, in seconds.
///
/// @returns: void
pub fn step(self: *Game, input: Input, dt: f32) void {
    // For now just do nothing with the input
    _ = input;
    _ = self;
    _ = dt;
}
