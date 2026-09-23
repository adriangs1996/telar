//! A chrome canvas over the embedded JetBrains Mono atlas, without a session.
const data = @import("model");
const assets = @import("assets");
const ChromeMetrics = @import("../widgets/ChromeMetrics.zig");
const std = @import("std");
const client = @import("telar-client");
const GlyphAtlas = @import("../text/GlyphAtlas.zig");
const QuadList = @import("../render/QuadList.zig");
const Canvas = @import("../widgets/Canvas.zig");
const Fixture = @This();

atlas: GlyphAtlas,
quads: QuadList,

pub fn init() !Fixture {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = assets.jetbrains_mono, .pixel_height = 16 });
    errdefer atlas.deinit();
    return .{ .atlas = atlas, .quads = QuadList.init(std.testing.allocator) };
}

pub fn deinit(self: *Fixture) void {
    self.quads.deinit();
    self.atlas.deinit();
}

/// Ten-pixel cells keep monospace widths easy to compare against sans
/// advances; the chrome sizes are the defaults at scale 1 (15, 13, 11).
/// Example: `var canvas = fixture.canvas();`
pub fn canvas(self: *Fixture) Canvas {
    return .{
        .atlas = &self.atlas,
        .quads = &self.quads,
        .origin = .{ 8, 12 },
        .metrics = .{ .cell_width = 10, .cell_height = 24, .baseline = 18, .pixel_height = 16 },
        .theme = data.theme_support.default_theme,
        .chrome = ChromeMetrics.resolve(.{}, 1),
    };
}
