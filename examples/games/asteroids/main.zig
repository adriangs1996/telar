const std = @import("std");

const Vec2 = struct {
    x: f32,
    y: f32,
};

const Turn = enum {
    left,
    right,
    none,
};

const Input = struct {
    turn: Turn,
    thrust: bool,
};

const Bounds = struct {
    width: f32,
    height: f32,
};

const Ship = struct {
    position: Vec2,
    velocity: Vec2,
    heading: f32,
};

const Game = struct {
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
};

const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

const Colors = struct {
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    pub const red: Color = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    pub const green: Color = .{ .r = 0, .g = 255, .b = 0, .a = 255 };
    pub const blue: Color = .{ .r = 0, .g = 0, .b = 255, .a = 255 };
};

const Pixel = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
    x: i32,
    y: i32,

    pub fn at(x: i32, y: i32, color: Color) Pixel {
        return Pixel{
            .r = color.r,
            .g = color.g,
            .b = color.b,
            .a = color.a,
            .x = x,
            .y = y,
        };
    }
};

const Frame = struct {
    pixels: []u8,
    width: usize,
    height: usize,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Frame {
        const pixel_count = try std.math.mul(usize, width, height);
        const byte_count = try std.math.mul(usize, pixel_count, 4);
        const pixels = try allocator.alloc(u8, byte_count);

        return Frame{
            .pixels = pixels,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *const Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    pub fn setPixel(self: *Frame, pixel: Pixel) void {
        if (pixel.x < 0 or pixel.y < 0) {
            return;
        }

        const x: usize = @intCast(pixel.x);
        const y: usize = @intCast(pixel.y);

        if (x >= self.width or y >= self.height) {
            return;
        }

        const offset = (x + y * self.width) * 4;
        self.pixels[offset] = pixel.r;
        self.pixels[offset + 1] = pixel.g;
        self.pixels[offset + 2] = pixel.b;
        self.pixels[offset + 3] = pixel.a;
    }

    pub fn clear(self: *Frame, color: Color) void {
        var offset: usize = 0;

        while (offset < self.pixels.len) : (offset += 4) {
            self.pixels[offset] = color.r;
            self.pixels[offset + 1] = color.g;
            self.pixels[offset + 2] = color.b;
            self.pixels[offset + 3] = color.a;
        }
    }
};

const Renderer = struct {
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
};

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
