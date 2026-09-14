//! A chrome canvas over the embedded JetBrains Mono atlas, without a session.
const std = @import("std");
const client = @import("telar-client");
const GlyphAtlas = @import("../text/GlyphAtlas.zig");
const QuadList = @import("../render/QuadList.zig");
const Canvas = @import("../widgets/Canvas.zig");
const Fixture = @This();

atlas: GlyphAtlas,
quads: QuadList,

pub fn init() !Fixture {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = @import("assets").jetbrains_mono, .pixel_height = 16 });
    errdefer atlas.deinit();
    return .{ .atlas = atlas, .quads = QuadList.init(std.testing.allocator) };
}

pub fn deinit(fixture: *Fixture) void {
    fixture.quads.deinit();
    fixture.atlas.deinit();
}

/// Ten-pixel cells keep monospace widths easy to compare against sans
/// advances; the chrome sizes are the defaults at scale 1 (15, 13, 11).
/// Example: `var canvas = fixture.canvas();`
pub fn canvas(fixture: *Fixture) Canvas {
    return .{
        .atlas = &fixture.atlas,
        .quads = &fixture.quads,
        .origin = .{ 8, 12 },
        .metrics = .{ .cell_width = 10, .cell_height = 24, .baseline = 18, .pixel_height = 16 },
        .theme = client.theme_support.default_theme,
        .chrome = @import("../widgets/ChromeMetrics.zig").resolve(.{}, 1),
    };
}
