const std = @import("std");
const Fixture = @This();

atlas: @import("../text/GlyphAtlas.zig"),
quads: @import("../render/QuadList.zig"),
clock: @import("../animation/FrameClock.zig") = .{},
state: ?*@import("../widgets/interaction/State.zig") = null,

pub fn init() !Fixture {
    return .{ .atlas = try @import("../text/GlyphAtlas.zig").init(std.testing.allocator, .{ .font = @import("assets").jetbrains_mono, .pixel_height = 15 }), .quads = @import("../render/QuadList.zig").init(std.testing.allocator) };
}

pub fn deinit(fixture: *Fixture) void {
    if (fixture.state) |state| {
        state.deinit();
        std.testing.allocator.destroy(state);
    }

    fixture.atlas.deinit();
    fixture.quads.deinit();
}

pub fn canvas(fixture: *Fixture) @import("../widgets/Canvas.zig") {
    return .{ .atlas = &fixture.atlas, .quads = &fixture.quads, .origin = .{ 0, 0 }, .metrics = .{ .cell_width = 9, .cell_height = 22, .baseline = 17, .pixel_height = 15 }, .theme = @import("telar-client").theme_support.default_theme, .chrome = .{ .body = 15, .title = 18, .small = 12, .ratio = 1 }, .animation = &fixture.clock, .widgets = fixture.state };
}

pub fn enableCache(fixture: *Fixture) !void {
    const state = try std.testing.allocator.create(@import("../widgets/interaction/State.zig"));
    state.* = .{};
    fixture.state = state;
}
