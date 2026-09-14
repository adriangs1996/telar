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
    _ = @import("../image/png.zig");
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

const ChromeFixture = @import("ChromeFixture.zig");
const Canvas = @import("../chrome/Canvas.zig");
const Context = @import("../chrome/Context.zig");
const HitMap = @import("../chrome/HitMap.zig");
const BandHitMap = @import("../chrome/BandHitMap.zig");
const AgentCard = @import("../chrome/AgentCard.zig");
const CardGeometry = @import("../chrome/CardGeometry.zig");

fn agent(provider: core.AgentProvider, pane: u32) client.AgentInput {
    return .{ .key = .{ .pane_id = @enumFromInt(pane), .pane_generation = 1 }, .location = Session.location, .pane_index = 1, .provider = provider, .status = .ready, .status_age_s = 1, .workspace_label = "telar", .session_title = "title", .last_event = "event" };
}

test "the card draws the sheet mark for the three providers and the chip for a custom one" {
    var fixture = try ChromeFixture.init();
    defer fixture.deinit();
    const renderer = &fixture.session.renderer;
    var agents: client.AgentSnapshot = .{};
    _ = try agents.replace(.{ .revision = 1, .agents = &.{ agent(.claude, 51), agent(.codex, 52), agent(.pi, 53), agent(.unknown, 54), agent(@enumFromInt(7), 55) } });
    var projection = fixture.projection();
    projection.agents = &agents;
    var hits: HitMap = .{};
    var band_hits: BandHitMap = .{};
    var canvas: Canvas = .{ .atlas = &renderer.atlas.?, .quads = &renderer.quads, .metrics = renderer.metrics, .origin = renderer.origin, .theme = fixture.session.gui.theme, .sprites = &renderer.sprites.? };
    var context: Context = .{ .canvas = &canvas, .hits = &hits, .bands = &band_hits, .projection = &projection, .hovered = null };
    const geometry = CardGeometry.derive(renderer.metrics);
    const page = &renderer.sprites.?;
    for (agents.slice(), 0..) |*entry, index| {
        renderer.quads.clear();
        const card: AgentCard = .{ .context = &context, .agent = entry, .geometry = geometry, .age_s = 1 };
        try card.paint(.{ .x = 100, .y = 100, .width = 300, .height = geometry.height() });
        const quads = renderer.quads.items();
        if (index < 3) {
            try std.testing.expectEqual(@as(usize, 1), spriteCount(quads));
            const expected = page.uv(page.providerMark(entry.provider).?);
            var found = false;
            for (quads) |item| {
                if (item.texture == quad.sprite_texture) {
                    try std.testing.expectEqualSlices(f32, &expected, &.{ item.u0, item.v0, item.u1, item.v1 });
                    try std.testing.expectEqual(CardGeometry.mark_size, item.width);
                    found = true;
                }
            }

            try std.testing.expect(found);
        } else {
            try std.testing.expectEqual(@as(usize, 0), spriteCount(quads));
            var chips: usize = 0;
            for (quads) |item| {
                chips += @intFromBool(item.radius == 4 and item.border == 0);
            }

            try std.testing.expectEqual(@as(usize, 1), chips);
        }
    }

    // A resolved favicon replaces the generic glyph with one sprite in row 1.
    renderer.quads.clear();
    const cell = page.cell;
    const pixels = try std.testing.allocator.alloc(u8, cell * cell * 4);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 255);
    const icon = try page.addFavicon(.{ .pixels = pixels, .stride = cell * 4, .width = cell, .height = cell });
    const card: AgentCard = .{ .context = &context, .agent = &agents.slice()[0], .geometry = geometry, .age_s = 1, .project_icon = icon };
    try card.paint(.{ .x = 100, .y = 100, .width = 300, .height = geometry.height() });
    try std.testing.expectEqual(@as(usize, 2), spriteCount(renderer.quads.items()));
    try std.testing.expect(try card.level(300) == .full);
}

test "a warm repaint with sprites shapes rasterizes and allocates nothing" {
    var fixture = try ChromeFixture.init();
    defer fixture.deinit();
    var agents: client.AgentSnapshot = .{};
    _ = try agents.replace(.{ .revision = 1, .agents = &.{ agent(.claude, 51), agent(.codex, 52), agent(.pi, 53), agent(.unknown, 54) } });
    var projection = fixture.projection();
    projection.agents = &agents;
    projection.sidebar_visible = true;
    try fixture.paint(projection);
    const renderer = &fixture.session.renderer;
    const count = renderer.quads.items().len;
    try std.testing.expectEqual(@as(usize, 3), spriteCount(renderer.quads.items()));
    const atlas = &renderer.atlas.?;
    const version = atlas.version;
    const calls = atlas.shape_calls;
    const rasters = atlas.raster_attempts;
    renderer.seal();
    const sprites_version = renderer.sprites_version;
    var failure = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const allocator = atlas.allocator;
    atlas.allocator = failure.allocator();
    defer atlas.allocator = allocator;
    const quad_allocator = renderer.quads.allocator;
    renderer.quads.allocator = failure.allocator();
    defer renderer.quads.allocator = quad_allocator;
    for (0..30) |frame| {
        projection.sidebar_animation_frame = @intCast(frame);
        try fixture.paint(projection);
        renderer.seal();
    }

    try std.testing.expectEqual(count, renderer.quads.items().len);
    try std.testing.expectEqual(version, atlas.version);
    try std.testing.expectEqual(calls, atlas.shape_calls);
    try std.testing.expectEqual(rasters, atlas.raster_attempts);
    try std.testing.expectEqual(sprites_version, renderer.sprites_version);
    try std.testing.expectEqual(@as(usize, 0), failure.allocations);
}
