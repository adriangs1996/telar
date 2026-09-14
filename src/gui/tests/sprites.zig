//! Slice 8 of the GUI visual language: the RGBA sprite page beside the alpha
//! atlas, the quads that select it, the provider marks on the card and the
//! favicon that reaches `project_icon`.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const CanvasFixture = @import("CanvasFixture.zig");
const Session = @import("Session.zig");
const SpritePage = @import("../image/SpritePage.zig");
const Quad = @import("../render/Quad.zig").Quad;
const quad = @import("../render/Quad.zig");

test {
    _ = SpritePage;
    _ = @import("../image/box_filter.zig");
}

/// Quads sampling the sprite page.
pub fn spriteCount(quads: []const Quad) usize {
    var count: usize = 0;
    for (quads) |item| {
        count += @intFromBool(item.texture == quad.sprite_texture);
    }

    return count;
}

test "the renderer builds the page with the atlas and versions it per change" {
    const session = try Session.init();
    defer session.deinit();
    const renderer = &session.renderer;
    const page = &renderer.sprites.?;
    try std.testing.expectEqual(SpritePage.cellFor(1), page.cell);
    try std.testing.expectEqual(@as(u16, 3), page.count);
    var frame = renderer.frame(1);
    try std.testing.expectEqual(SpritePage.side, frame.sprites_side);
    try std.testing.expect(frame.sprites != null);
    renderer.seal();
    const version = renderer.sprites_version;
    try std.testing.expect(version != 0);
    renderer.seal();
    try std.testing.expectEqual(version, renderer.sprites_version);

    const cell = page.cell;
    const pixels = try std.testing.allocator.alloc(u8, cell * cell * 4);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 200);
    _ = try page.addFavicon(.{ .pixels = pixels, .stride = cell * 4, .width = cell, .height = cell });
    renderer.seal();
    try std.testing.expectEqual(version + 1, renderer.sprites_version);
    frame = renderer.frame(2);
    try std.testing.expectEqual(version + 1, frame.sprites_version);

    // A new scale rebuilds the page at its cell with the provider marks only.
    _ = try renderer.measure(.{ .width = 360, .height = 480, .scale = 2 });
    try std.testing.expectEqual(SpritePage.cellFor(2), renderer.sprites.?.cell);
    try std.testing.expectEqual(@as(u16, 3), renderer.sprites.?.count);
    try std.testing.expectEqual(@as(u32, 0), renderer.last_sprites_version);
}

test "sprite quads carry the texture selector and plain quads stay on the atlas" {
    var fixture = try CanvasFixture.init();
    defer fixture.deinit();
    var page = try SpritePage.init(std.testing.allocator, 16);
    defer page.deinit();
    var canvas = fixture.canvas();
    canvas.sprites = &page;
    try canvas.fillAt(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, .default);
    try canvas.spriteAt(.{ .x = 10.5, .y = 20.25, .width = 16, .height = 16 }, canvas.providerMark(.codex).?);
    try canvas.text(.{ .x = 0, .y = 1, .w = 4, .h = 1 }, .{ .text = "ab" });
    const quads = fixture.quads.items();
    try std.testing.expectEqual(@as(usize, 1), spriteCount(quads));
    try std.testing.expectEqual(quad.atlas_texture, quads[0].texture);
    const sprite = quads[1];
    try std.testing.expectEqual(@as(f32, 10), sprite.x);
    try std.testing.expectEqual(@as(f32, 20), sprite.y);
    try std.testing.expectEqualSlices(f32, &page.uv(.{ .index = 1 }), &.{ sprite.u0, sprite.v0, sprite.u1, sprite.v1 });
    try std.testing.expectEqual(@as(f32, 1), sprite.a);
    try std.testing.expectEqual(@as(f32, 0), sprite.radius);
    for (quads[2..]) |glyph| {
        try std.testing.expectEqual(quad.atlas_texture, glyph.texture);
    }

    canvas.sprites = null;
    try canvas.spriteAt(.{ .x = 0, .y = 0, .width = 16, .height = 16 }, .{ .index = 0 });
    try std.testing.expectEqual(quads.len, fixture.quads.items().len);
    try std.testing.expect(canvas.providerMark(.claude) == null);
}
