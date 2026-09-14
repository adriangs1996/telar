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
    try canvas.fillAt(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, .{ .rgb = .{ 1, 2, 3 } });
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
    var canvas: Canvas = .{ .atlas = &renderer.atlas.?, .quads = &renderer.quads, .metrics = renderer.metrics, .origin = renderer.origin, .theme = fixture.session.gui.theme, .chrome = renderer.chrome, .sprites = &renderer.sprites.? };
    var context: Context = .{ .canvas = &canvas, .hits = &hits, .bands = &band_hits, .projection = &projection, .hovered = null };
    const geometry = CardGeometry.derive(renderer.chrome, renderer.metrics);
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
                    try std.testing.expectEqual(@round(canvas.chrome.px(CardGeometry.mark_size)), item.width);
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

const Favicons = @import("../chrome/Favicons.zig");
const png = @import("../image/png.zig");
const favicon_worker = @import("../image/favicon_worker.zig");

fn cellImage(side: u16, value: u8) !*client.FaviconImage {
    const image = try std.testing.allocator.create(client.FaviconImage);
    image.* = .{ .side = side };
    @memset(image.mutableSlice(), value);
    return image;
}

test "the registry places one landed image per workspace and forgets a rebuilt page" {
    const gpa = std.testing.allocator;
    var page = try SpritePage.init(gpa, 16);
    defer page.deinit();
    var workspaces: client.WorkspaceListSnapshot = .{};
    _ = try workspaces.replace(.{ .revision = 1, .entries = &.{
        .{ .workspace = @enumFromInt(1), .name = "a", .path = "/a", .tab_count = 1 },
        .{ .workspace = @enumFromInt(2), .name = "b", .path = "/b", .tab_count = 1 },
    } });
    var favicons: Favicons = .{};
    defer favicons.deinit(gpa);
    favicons.refresh(gpa, &page);
    const first = favicons.next(&workspaces).?;
    try std.testing.expectEqual(@as(core.WorkspaceId, @enumFromInt(1)), first.workspace);
    try std.testing.expectEqualStrings("/a", first.cwd);
    try std.testing.expectEqual(first.workspace, favicons.next(&workspaces).?.workspace);
    favicons.started(first.workspace);
    try std.testing.expectEqual(@as(core.WorkspaceId, @enumFromInt(2)), favicons.next(&workspaces).?.workspace);
    favicons.started(@enumFromInt(2));
    try std.testing.expect(favicons.next(&workspaces) == null);

    favicons.land(gpa, .{ .workspace = @enumFromInt(1), .image = try cellImage(16, 200) });
    try std.testing.expect(favicons.sprite(.{ .workspace = @enumFromInt(1) }) == null);
    favicons.refresh(gpa, &page);
    const placed = favicons.sprite(.{ .workspace = @enumFromInt(1) }).?;
    try std.testing.expectEqual(@as(u16, 3), placed.index);
    try std.testing.expectEqual(@as(u16, 4), page.count);
    try std.testing.expect(favicons.sprite(.{ .worktree = @enumFromInt(1) }) == null);

    favicons.land(gpa, .{ .workspace = @enumFromInt(2), .image = null });
    favicons.refresh(gpa, &page);
    try std.testing.expectEqual(Favicons.capacity, @as(usize, core.max_workspace_list_entries));
    try std.testing.expect(favicons.stateOf(@enumFromInt(2)) == .missing);
    try std.testing.expect(favicons.sprite(.{ .workspace = @enumFromInt(2) }) == null);

    // A landing for a workspace the registry never saw is released unread.
    favicons.land(gpa, .{ .workspace = @enumFromInt(9), .image = try cellImage(16, 1) });
    favicons.refresh(gpa, &page);
    try std.testing.expectEqual(@as(u16, 4), page.count);

    // A cell of the wrong size asks for the lookup again.
    _ = try workspaces.replace(.{ .revision = 2, .entries = &.{
        .{ .workspace = @enumFromInt(1), .name = "a", .path = "/a", .tab_count = 1 },
        .{ .workspace = @enumFromInt(3), .name = "c", .path = "/c", .tab_count = 1 },
    } });
    favicons.started(favicons.next(&workspaces).?.workspace);
    favicons.land(gpa, .{ .workspace = @enumFromInt(3), .image = try cellImage(8, 1) });
    favicons.refresh(gpa, &page);
    try std.testing.expect(favicons.stateOf(@enumFromInt(3)) == .wanted);

    // A full sheet keeps the glyph.
    while (page.faviconRoom() != 0) {
        const filler = try cellImage(16, 7);
        defer gpa.destroy(filler);
        _ = try page.addFavicon(.{ .pixels = filler.slice(), .stride = 64, .width = 16, .height = 16 });
    }

    favicons.started(@enumFromInt(3));
    favicons.land(gpa, .{ .workspace = @enumFromInt(3), .image = try cellImage(16, 1) });
    favicons.refresh(gpa, &page);
    try std.testing.expect(favicons.stateOf(@enumFromInt(3)) == .full);
    try std.testing.expect(favicons.next(&workspaces) == null);

    // Another page forgets every placement, so the lookups run again.
    var rebuilt = try SpritePage.init(gpa, 32);
    defer rebuilt.deinit();
    favicons.refresh(gpa, &rebuilt);
    try std.testing.expect(favicons.sprite(.{ .workspace = @enumFromInt(1) }) == null);
    try std.testing.expectEqual(@as(core.WorkspaceId, @enumFromInt(1)), favicons.next(&workspaces).?.workspace);
}

test "the favicon worker decodes a workspace favicon.png into the sprite cell" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try temp.dir.realPath(io, &root_buffer)];
    const missing = favicon_worker.execute(io, gpa, .init(.{ .execution_id = @enumFromInt(1), .workspace = @enumFromInt(1), .cell = 16 }, root));
    try std.testing.expectError(error.FaviconNotFound, missing.result);

    const samples = [_]u8{ 0, 0, 255, 255 } ** 64;
    const bytes = try png.encodeForTest(gpa, .{ .header = .{ .width = 8, .height = 8, .color = .rgba }, .filter = 2 }, &samples);
    defer gpa.free(bytes);
    try temp.dir.writeFile(io, .{ .sub_path = "favicon.png", .data = bytes });
    const landed = favicon_worker.execute(io, gpa, .init(.{ .execution_id = @enumFromInt(2), .workspace = @enumFromInt(1), .cell = 16 }, root));
    const image = try landed.result;
    defer gpa.destroy(image);
    try std.testing.expectEqual(@as(core.WorkspaceId, @enumFromInt(1)), landed.workspace);
    try std.testing.expectEqual(@as(u16, 16), image.side);
    for (0..256) |index| {
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, image.slice()[index * 4 ..][0..4]);
    }

    try temp.dir.writeFile(io, .{ .sub_path = "favicon.png", .data = "GIF89a not a png but long enough to be read" });
    try std.testing.expectError(error.NotPng, favicon_worker.execute(io, gpa, .init(.{ .execution_id = @enumFromInt(3), .workspace = @enumFromInt(1), .cell = 16 }, root)).result);
    try std.testing.expectError(error.InvalidSpriteCell, favicon_worker.execute(io, gpa, .init(.{ .execution_id = @enumFromInt(4), .workspace = @enumFromInt(1), .cell = 0 }, root)).result);
}

test "a workspace favicon reaches the card one frame after the worker completes" {
    var fixture = try ChromeFixture.init();
    defer fixture.deinit();
    const session = fixture.session;
    const gui = session.gui;
    const renderer = &session.renderer;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try temp.dir.realPath(io, &root_buffer)];
    const samples = [_]u8{ 255, 0, 0, 255 } ** 64;
    const bytes = try png.encodeForTest(gpa, .{ .header = .{ .width = 8, .height = 8, .color = .rgba }, .filter = 1 }, &samples);
    defer gpa.free(bytes);
    try temp.dir.createDirPath(io, ".telar");
    try temp.dir.writeFile(io, .{ .sub_path = ".telar/icon.png", .data = bytes });
    const workspace = Session.location.workspace.workspace;
    _ = try gui.app.model.workspace_list_snapshot.replace(.{ .revision = 1, .entries = &.{.{ .workspace = workspace, .name = "telar", .path = root, .tab_count = 1 }} });

    // The first preparation starts the lookup; its completion lands through
    // the inbox and the next preparation places the cell.
    const first = try gui.prepare(renderer);
    try gui.complete(first, true);
    try std.testing.expect(gui.chrome.favicons.stateOf(workspace) == .pending);
    try std.testing.expect(gui.app.favicons.busy());
    var rounds: usize = 0;
    while (gui.chrome.favicons.stateOf(workspace) != .resolved) : (rounds += 1) {
        if (rounds == 8) {
            return error.FaviconNeverLanded;
        }

        try session.driver.inbox.wait();
        _ = try gui.pump();
        const token = try gui.prepare(renderer);
        try gui.complete(token, true);
    }

    try std.testing.expect(!gui.app.favicons.busy());
    const placed = gui.chrome.favicons.sprite(Session.location.workspace).?;
    try std.testing.expectEqual(@as(u16, 3), placed.index);
    try std.testing.expectEqual(@as(u16, 4), renderer.sprites.?.count);
    renderer.seal();
    const version = renderer.sprites_version;
    const again = try gui.prepare(renderer);
    try gui.complete(again, true);
    try std.testing.expectEqual(version, renderer.sprites_version);

    var agents: client.AgentSnapshot = .{};
    _ = try agents.replace(.{ .revision = 1, .agents = &.{agent(.claude, 51)} });
    var projection = fixture.projection();
    projection.agents = &agents;
    projection.sidebar_visible = true;
    fixture.chrome.favicons = gui.chrome.favicons;
    try fixture.paint(projection);
    try std.testing.expectEqual(@as(usize, 2), spriteCount(renderer.quads.items()));
    var found = false;
    for (renderer.quads.items()) |item| {
        if (item.texture == quad.sprite_texture and item.u0 == renderer.sprites.?.uv(placed)[0] and item.v0 == renderer.sprites.?.uv(placed)[1]) {
            found = true;
        }
    }

    try std.testing.expect(found);
}
