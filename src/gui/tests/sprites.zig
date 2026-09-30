//! Slice 8 of the GUI visual language: the RGBA sprite page beside the alpha
//! atlas, the quads that select it, the provider marks on the card and the
//! favicon that reaches `project_icon`.
const data = @import("model");
const input_support = @import("input_support.zig");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const CanvasFixture = @import("CanvasFixture.zig");
const Session = @import("Session.zig");
const SpritePage = @import("../image/SpritePage.zig");
const Sprite = @import("../image/Sprite.zig");
const gfx = @import("gfx");
const Quad = gfx.Quad.Quad;
const quad = gfx.Quad;

test {
    _ = SpritePage;
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
    const renderer = &session.gui.renderer;
    const page = &renderer.sprites.?;
    try std.testing.expectEqualSlices(u16, &SpritePage.cellsFor(renderer.chrome.ratio), &page.cells);
    try std.testing.expectEqual(SpritePage.provider_mark_count, page.count);
    var frame = renderer.frame(1);
    try std.testing.expectEqual(page.side, frame.sprites_side);
    try std.testing.expect(frame.sprites != null);
    renderer.seal();
    const version = renderer.sprites_version;
    try std.testing.expect(version != 0);
    renderer.seal();
    try std.testing.expectEqual(version, renderer.sprites_version);

    const slot = try placeFavicon(page, 200);
    renderer.seal();
    try std.testing.expectEqual(version + 1, renderer.sprites_version);
    frame = renderer.frame(2);
    try std.testing.expectEqual(version + 1, frame.sprites_version);

    // A released slot is cleared on the page, so the GPU uploads it again.
    page.removeFavicon(slot);
    renderer.seal();
    try std.testing.expectEqual(version + 2, renderer.sprites_version);

    // A new scale rebuilds the page at its cell with the provider marks only.
    const ratio = renderer.chrome.ratio;
    _ = try renderer.measure(.{ .width = 360, .height = 480, .scale = 2 });
    try std.testing.expectEqual(2 * ratio, renderer.chrome.ratio);
    try std.testing.expectEqualSlices(u16, &SpritePage.cellsFor(renderer.chrome.ratio), &renderer.sprites.?.cells);
    try std.testing.expectEqual(SpritePage.provider_mark_count, renderer.sprites.?.count);
    try std.testing.expectEqual(renderer.sprites.?.side, renderer.frame(3).sprites_side);
    try std.testing.expectEqual(@as(u32, 0), renderer.last_sprites_version);
}

test "sprite quads carry the texture selector and plain quads stay on the atlas" {
    var fixture = try CanvasFixture.init();
    defer fixture.deinit();
    var page = try SpritePage.init(std.testing.allocator, 1);
    defer page.deinit();
    var canvas = fixture.canvas();
    canvas.sprites = &page;
    try canvas.fillAt(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, .rgb(.{ 1, 2, 3 }));
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
const Canvas = @import("../widgets/Canvas.zig");
const Context = @import("../widgets/Context.zig");
const HitMap = @import("../widgets/HitMap.zig");
const BandHitMap = @import("../widgets/BandHitMap.zig");
const AgentCard = @import("../widgets/AgentCard.zig");
const CardGeometry = @import("../widgets/CardGeometry.zig");

fn agent(provider: core.AgentProvider, pane: u32) data.AgentInput {
    return .{ .key = .{ .pane_id = @enumFromInt(pane), .pane_generation = 1 }, .location = Session.location, .pane_index = 1, .provider = provider, .status = .ready, .status_age_s = 1, .workspace_label = "telar", .session_title = "title", .last_event = "event" };
}

test "the card draws the sheet mark for the three providers and an unboxed glyph for a custom one" {
    var fixture = try ChromeFixture.init();
    defer fixture.deinit();
    const renderer = &fixture.session.gui.renderer;
    var agents: data.AgentSnapshot = .{};
    _ = try agents.replace(.{ .revision = 1, .agents = &.{ agent(.claude, 51), agent(.codex, 52), agent(.pi, 53), agent(.unknown, 54), agent(@enumFromInt(7), 55) } });
    var projection = fixture.projection();
    projection.agents = &agents;
    var hits: HitMap = .{};
    var band_hits: BandHitMap = .{};
    var canvas: Canvas = .{ .atlas = &renderer.atlas.?, .quads = &renderer.quads, .metrics = renderer.metrics, .origin = renderer.origin, .theme = fixture.session.gui.app.model.theme, .chrome = renderer.chrome, .sprites = &renderer.sprites.? };
    const context: Context = .{ .hits = &hits, .bands = &band_hits, .projection = &projection, .hovered = null };
    const geometry = CardGeometry.derive(renderer.chrome, renderer.metrics);
    const page = &renderer.sprites.?;
    for (agents.slice(), 0..) |*entry, index| {
        renderer.quads.clear();
        const card: AgentCard = .{ .context = &context, .bounds = .{ .x = 100, .y = 100, .width = 300, .height = geometry.height() }, .agent = entry, .geometry = geometry, .age_s = 1 };
        try card.draw(&canvas);
        const quads = renderer.quads.items();
        if (index < 3) {
            try std.testing.expectEqual(@as(usize, 1), spriteCount(quads));
            const expected = page.uv(page.providerMark(entry.provider).?);
            var found = false;
            for (quads) |item| {
                if (item.texture == quad.sprite_texture) {
                    try std.testing.expectEqualSlices(f32, &expected, &.{ item.u0, item.v0, item.u1, item.v1 });
                    try std.testing.expectEqual(@round(canvas.chrome.px(CardGeometry.mark_size)), item.width);
                    try std.testing.expectEqual(AgentCard.provider_alpha, item.a);
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

            try std.testing.expectEqual(@as(usize, 0), chips);
        }
    }

    // A resolved favicon replaces the generic glyph with one sprite in row 1,
    // drawn at its `small` cell one texel per pixel.
    renderer.quads.clear();
    const icon: Sprite = .{
        .index = try placeFavicon(page, 255),
        .size = .small,
    };
    const card: AgentCard = .{ .context = &context, .bounds = .{ .x = 100, .y = 100, .width = 300, .height = geometry.height() }, .agent = &agents.slice()[0], .geometry = geometry, .age_s = 1, .project_icon = icon };
    try card.draw(&canvas);
    try std.testing.expectEqual(@as(usize, 2), spriteCount(renderer.quads.items()));
    try std.testing.expectEqual(@as(usize, 1), oneTexelPerPixel(renderer.quads.items(), page, icon));
}

test "a warm repaint with sprites shapes rasterizes and allocates nothing" {
    var fixture = try ChromeFixture.init();
    defer fixture.deinit();
    var agents: data.AgentSnapshot = .{};
    var inputs = [_]data.AgentInput{
        agent(.claude, 51),
        agent(.codex, 52),
        agent(.pi, 53),
        agent(.unknown, 54),
    };
    for (&inputs) |*input| {
        input.status = .working;
        // Keep the elapsed label stable while exercising every opacity step.
        input.status_age_s = 120;
    }

    _ = try agents.replace(.{ .revision = 1, .agents = &inputs });
    var projection = fixture.projection();
    projection.agents = &agents;
    try fixture.paint(projection);
    const renderer = &fixture.session.gui.renderer;
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
        fixture.chrome.now_ns = frame * 120 * std.time.ns_per_ms;
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

const Favicons = @import("../widgets/Favicons.zig");
const imaging = @import("imaging");
const png = imaging.png;
const favicon_worker = @import("../image/favicon_worker.zig");

fn cellImage(sides: client.FaviconImage.Sides, value: u8) !*client.FaviconImage {
    const image = try std.testing.allocator.create(client.FaviconImage);
    image.* = .{ .sides = sides };
    for (0..sides.len) |index| {
        @memset(image.mutableSlice(index), value);
    }

    return image;
}

/// Places one flat favicon at every size of `page` and returns its slot.
pub fn placeFavicon(page: *SpritePage, value: u8) !u16 {
    const image = try cellImage(page.cells, value);
    defer std.testing.allocator.destroy(image);
    var images: SpritePage.Images = undefined;
    for (&images, image.sides, 0..) |*view, side, index| {
        view.* = .{ .pixels = image.slice(index), .stride = @as(u32, side) * 4, .width = side, .height = side };
    }

    return page.addFavicon(images);
}

/// Sprite quads that draw `sprite` at its cell's own side, snapped to whole
/// pixels, so the GPU samples one texel per pixel.
pub fn oneTexelPerPixel(quads: []const Quad, page: *const SpritePage, sprite: Sprite) usize {
    const expected = page.uv(sprite);
    const side: f32 = @floatFromInt(page.cell(sprite.size));
    var count: usize = 0;
    for (quads) |item| {
        if (item.texture != quad.sprite_texture or !std.mem.eql(f32, &expected, &.{ item.u0, item.v0, item.u1, item.v1 })) {
            continue;
        }

        count += @intFromBool(item.width == side and item.height == side and item.x == @floor(item.x) and item.y == @floor(item.y));
    }

    return count;
}

test "the registry places one landed image per workspace and forgets a rebuilt page" {
    const gpa = std.testing.allocator;
    var page = try SpritePage.init(gpa, 1);
    defer page.deinit();
    var workspaces: data.WorkspaceListSnapshot = .{};
    _ = try workspaces.replace(.{ .revision = 1, .entries = &.{
        .{ .workspace = @enumFromInt(1), .name = "a", .path = "/a", .tab_count = 1 },
        .{ .workspace = @enumFromInt(2), .name = "b", .path = "/b", .tab_count = 1 },
    } });
    var favicons: Favicons = .{};
    defer favicons.deinit(gpa);
    try std.testing.expect(favicons.refresh(gpa, &page, &workspaces) == null);
    const first = favicons.next(&page, &workspaces).?;
    try std.testing.expectEqual(@as(core.WorkspaceId, @enumFromInt(1)), first.workspace);
    try std.testing.expectEqualStrings("/a", first.cwd);
    try std.testing.expectEqual(first.workspace, favicons.next(&page, &workspaces).?.workspace);
    favicons.started(first.workspace);
    try std.testing.expectEqual(@as(core.WorkspaceId, @enumFromInt(2)), favicons.next(&page, &workspaces).?.workspace);
    favicons.started(@enumFromInt(2));
    try std.testing.expect(favicons.next(&page, &workspaces) == null);

    favicons.land(gpa, .{ .workspace = @enumFromInt(1), .image = try cellImage(page.cells, 200) });
    try std.testing.expect(favicons.sprite(.{ .workspace = @enumFromInt(1) }, .small) == null);
    try std.testing.expect(favicons.refresh(gpa, &page, &workspaces) == null);
    const placed = favicons.sprite(.{ .workspace = @enumFromInt(1) }, .medium).?;
    try std.testing.expect(placed.size == .medium);
    try std.testing.expectEqual(SpritePage.provider_mark_count, placed.index);
    try std.testing.expectEqual(SpritePage.provider_mark_count + 1, page.count);
    try std.testing.expect(favicons.sprite(.{ .worktree = @enumFromInt(1) }, .small) == null);

    favicons.land(gpa, .{ .workspace = @enumFromInt(2), .image = null });
    try std.testing.expect(favicons.refresh(gpa, &page, &workspaces) == null);
    try std.testing.expectEqual(Favicons.capacity, @as(usize, core.max_workspace_list_entries));
    try std.testing.expect(favicons.stateOf(@enumFromInt(2)) == .missing);
    try std.testing.expect(favicons.sprite(.{ .workspace = @enumFromInt(2) }, .small) == null);

    // A landing for a workspace the registry never saw is released unread.
    favicons.land(gpa, .{ .workspace = @enumFromInt(9), .image = try cellImage(page.cells, 1) });
    try std.testing.expect(favicons.refresh(gpa, &page, &workspaces) == null);
    try std.testing.expectEqual(SpritePage.provider_mark_count + 1, page.count);

    // A cell of the wrong size asks for the lookup again.
    _ = try workspaces.replace(.{ .revision = 2, .entries = &.{
        .{ .workspace = @enumFromInt(1), .name = "a", .path = "/a", .tab_count = 1 },
        .{ .workspace = @enumFromInt(3), .name = "c", .path = "/c", .tab_count = 1 },
    } });
    favicons.started(favicons.next(&page, &workspaces).?.workspace);
    favicons.land(gpa, .{ .workspace = @enumFromInt(3), .image = try cellImage(.{ 14, 18, 8 }, 1) });
    try std.testing.expect(favicons.refresh(gpa, &page, &workspaces) == null);
    try std.testing.expect(favicons.stateOf(@enumFromInt(3)) == .wanted);

    // A full sheet keeps the glyph.
    while (page.faviconRoom() != 0) {
        _ = try placeFavicon(&page, 7);
    }

    favicons.started(@enumFromInt(3));
    favicons.land(gpa, .{ .workspace = @enumFromInt(3), .image = try cellImage(page.cells, 1) });
    const reach = favicons.refresh(gpa, &page, &workspaces).?;
    try std.testing.expectEqualStrings("gui.favicons.max_favicons", reach.limit.name);
    try std.testing.expectEqual(@as(u64, SpritePage.max_favicons), reach.limit.value);
    try std.testing.expectEqual(@as(?u64, SpritePage.max_favicons + 1), reach.requested);
    try std.testing.expect(favicons.stateOf(@enumFromInt(3)) == .full);
    try std.testing.expect(favicons.sprite(.{ .workspace = @enumFromInt(3) }, .small) == null);
    try std.testing.expect(favicons.next(&page, &workspaces) == null);

    // Another page forgets every placement, so the lookups run again.
    var rebuilt = try SpritePage.init(gpa, 2);
    defer rebuilt.deinit();
    try std.testing.expect(favicons.refresh(gpa, &rebuilt, &workspaces) == null);
    try std.testing.expect(favicons.sprite(.{ .workspace = @enumFromInt(1) }, .large) == null);
    try std.testing.expectEqual(@as(core.WorkspaceId, @enumFromInt(1)), favicons.next(&rebuilt, &workspaces).?.workspace);
}

/// Lists the workspaces `first` up to `first + len - 1` under one revision.
fn listWorkspaces(workspaces: *data.WorkspaceListSnapshot, first: u32, len: u32) !void {
    var entries: [core.max_workspace_list_entries]data.EntryInput = undefined;
    for (entries[0..len], first..) |*entry, id| {
        entry.* = .{
            .workspace = @enumFromInt(id),
            .name = "w",
            .path = "/w",
            .tab_count = 1,
        };
    }

    _ = try workspaces.replace(.{
        .revision = workspaces.revision + 1,
        .entries = entries[0..len],
    });
}

/// Answers every lookup the registry wants with a flat image and returns
/// the last limit a placement reached.
fn landEveryLookup(favicons: *Favicons, page: *SpritePage, workspaces: *const data.WorkspaceListSnapshot) !?core.LimitReach {
    var reach: ?core.LimitReach = null;
    while (favicons.next(page, workspaces)) |want| {
        favicons.started(want.workspace);
        favicons.land(std.testing.allocator, .{ .workspace = want.workspace, .image = try cellImage(page.cells, 9) });
        reach = favicons.refresh(std.testing.allocator, page, workspaces) orelse reach;
    }

    return reach;
}

test "workspaces that come and go keep finding favicon slots in one page" {
    const gpa = std.testing.allocator;
    var page = try SpritePage.init(gpa, 1);
    defer page.deinit();
    var workspaces: data.WorkspaceListSnapshot = .{};
    var favicons: Favicons = .{};
    defer favicons.deinit(gpa);

    // Three times the page's favicons pass through a list that shows at
    // most 64 at once, sliding by one workspace at a time.
    const listed: u32 = core.max_workspace_list_entries;
    const total: u32 = 3 * SpritePage.max_favicons;
    for (1..total + 1) |newest| {
        const first: u32 = @intCast(@max(1, @as(i64, @intCast(newest)) - listed + 1));
        try listWorkspaces(&workspaces, first, @as(u32, @intCast(newest)) - first + 1);
        try std.testing.expect(try landEveryLookup(&favicons, &page, &workspaces) == null);
        const sprite = favicons.sprite(.{ .workspace = @enumFromInt(newest) }, .large).?;
        try std.testing.expect(sprite.index >= SpritePage.provider_mark_count);
    }

    // Every listed workspace still shows its own favicon, and the page never
    // grew past its favicons.
    var seen: std.StaticBitSet(SpritePage.provider_mark_count + SpritePage.max_favicons) = .initEmpty();
    for (0..workspaces.count) |index| {
        const sprite = favicons.sprite(.{ .workspace = workspaces.workspaceAt(index) }, .small).?;
        try std.testing.expect(!seen.isSet(sprite.index));
        seen.set(sprite.index);
    }

    try std.testing.expectEqual(SpritePage.provider_mark_count + SpritePage.max_favicons, page.count);
    try std.testing.expectEqual(@as(u16, 0), page.faviconRoom());

    // A whole new list takes the slots of the one it replaces.
    try listWorkspaces(&workspaces, total + 1, listed);
    try std.testing.expect(try landEveryLookup(&favicons, &page, &workspaces) == null);
    for (0..workspaces.count) |index| {
        try std.testing.expect(favicons.stateOf(workspaces.workspaceAt(index)) == .resolved);
    }
}

test "a page whose slots all belong to listed workspaces reports its limit and keeps the glyph" {
    const gpa = std.testing.allocator;
    var page = try SpritePage.init(gpa, 1);
    defer page.deinit();
    var workspaces: data.WorkspaceListSnapshot = .{};
    var favicons: Favicons = .{};
    defer favicons.deinit(gpa);
    const listed: u32 = core.max_workspace_list_entries;
    try listWorkspaces(&workspaces, 1, listed - 1);
    try std.testing.expect(try landEveryLookup(&favicons, &page, &workspaces) == null);

    // Something else holds the last free cell, so the 64th listed workspace
    // finds the page full of listed workspaces.
    _ = try placeFavicon(&page, 3);
    try listWorkspaces(&workspaces, 1, listed);
    const reach = (try landEveryLookup(&favicons, &page, &workspaces)).?;
    try std.testing.expectEqualStrings("gui.favicons.max_favicons", reach.limit.name);
    try std.testing.expectEqualStrings("favicons", reach.limit.noun);
    try std.testing.expect(favicons.stateOf(@enumFromInt(listed)) == .full);
    try std.testing.expect(favicons.sprite(.{ .workspace = @enumFromInt(listed) }, .large) == null);
    try std.testing.expect(favicons.sprite(.{ .workspace = @enumFromInt(1) }, .large) != null);

    // The same list tries no second placement on later frames.
    try std.testing.expect(try landEveryLookup(&favicons, &page, &workspaces) == null);
    try std.testing.expect(favicons.stateOf(@enumFromInt(listed)) == .full);

    // Once a workspace leaves, its cell goes to the one that was turned away.
    try listWorkspaces(&workspaces, 2, listed - 1);
    try std.testing.expect(try landEveryLookup(&favicons, &page, &workspaces) == null);
    try std.testing.expect(favicons.stateOf(@enumFromInt(listed)) == .resolved);
    try std.testing.expect(favicons.sprite(.{ .workspace = @enumFromInt(1) }, .large) == null);
}

test "the favicon worker decodes a workspace favicon.png into the sprite cell" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try temp.dir.realPath(io, &root_buffer)];
    const missing = favicon_worker.execute(io, gpa, .init(.{ .execution_id = @enumFromInt(1), .workspace = @enumFromInt(1), .cells = @splat(16) }, root));
    try std.testing.expectError(error.FaviconNotFound, missing.result);

    const samples = [_]u8{ 0, 0, 255, 255 } ** 64;
    const bytes = try png.encodeForTest(gpa, .{ .header = .{ .width = 8, .height = 8, .color = .rgba }, .filter = 2 }, &samples);
    defer gpa.free(bytes);
    try temp.dir.writeFile(io, .{ .sub_path = "favicon.png", .data = bytes });
    const landed = favicon_worker.execute(io, gpa, .init(.{ .execution_id = @enumFromInt(2), .workspace = @enumFromInt(1), .cells = @splat(16) }, root));
    const image = try landed.result;
    defer gpa.destroy(image);
    try std.testing.expectEqual(@as(core.WorkspaceId, @enumFromInt(1)), landed.workspace);
    for (0..image.sides.len) |size| {
        try std.testing.expectEqual(@as(u16, 16), image.sides[size]);
        for (0..256) |index| {
            try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, image.slice(size)[index * 4 ..][0..4]);
        }
    }

    // A source smaller than the cell is blended, never repeated in blocks.
    const checker = [_]u8{ 0, 0, 0, 255, 255, 255, 255, 255 } ** 4 ++ [_]u8{ 255, 255, 255, 255, 0, 0, 0, 255 } ** 4;
    const small = try png.encodeForTest(gpa, .{ .header = .{ .width = 8, .height = 8, .color = .rgba } }, &(checker ** 4));
    defer gpa.free(small);
    try temp.dir.writeFile(io, .{ .sub_path = "favicon.png", .data = small });
    const retina_cells = SpritePage.cellsFor(2 * 23.0 / 15.0);
    const job: client.FaviconJob = .init(
        .{
            .execution_id = @enumFromInt(5),
            .workspace = @enumFromInt(1),
            .cells = retina_cells,
        },
        root,
    );
    const enlarged = try favicon_worker.execute(io, gpa, job).result;
    defer gpa.destroy(enlarged);
    try std.testing.expectEqualSlices(u16, &retina_cells, &enlarged.sides);

    for (0..enlarged.sides.len) |size| {
        const pixels = enlarged.slice(size);
        var greys: usize = 0;
        for (0..pixels.len / 4) |index| {
            const value = pixels[index * 4];
            greys += @intFromBool(value != 0 and value != 255);
        }

        try std.testing.expect(greys > pixels.len / 8);
    }

    try temp.dir.writeFile(io, .{ .sub_path = "favicon.png", .data = "GIF89a not a png but long enough to be read" });
    try std.testing.expectError(error.NotPng, favicon_worker.execute(io, gpa, .init(.{ .execution_id = @enumFromInt(3), .workspace = @enumFromInt(1), .cells = @splat(16) }, root)).result);
    try std.testing.expectError(error.InvalidSpriteCell, favicon_worker.execute(io, gpa, .init(.{ .execution_id = @enumFromInt(4), .workspace = @enumFromInt(1), .cells = .{ 16, 16, 0 } }, root)).result);
}

/// Runs the favicon worker over one `favicon.png` in a fresh directory.
fn lookUpFavicon(bytes: []const u8) !client.FaviconCompletion {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try temp.dir.realPath(io, &root_buffer)];
    try temp.dir.writeFile(io, .{ .sub_path = "favicon.png", .data = bytes });
    const job: client.FaviconJob = .init(
        .{
            .execution_id = @enumFromInt(1),
            .workspace = @enumFromInt(1),
            .cells = @splat(16),
        },
        root,
    );
    return favicon_worker.execute(io, std.testing.allocator, job);
}

fn flatFavicon(width: u32, height: u32) ![]u8 {
    return png.encodeFlatForTest(std.testing.allocator, .{ .header = .{ .width = width, .height = height, .color = .rgba } }, &.{ 30, 60, 90, 255 });
}

test "the favicon worker decodes a PNG up to its side bound and returns the reach past it" {
    const gpa = std.testing.allocator;

    // Past the decoder's default of 1 Mi pixels, a logo still lands.
    const logo = try flatFavicon(1025, 1024);
    defer gpa.free(logo);
    try std.testing.expect(logo.len <= client.favicon_lookup.max_file_bytes);
    const landed = try lookUpFavicon(logo);
    const image = try landed.result;
    defer gpa.destroy(image);
    try std.testing.expect(landed.limit == null);
    try std.testing.expectEqualSlices(u8, &.{ 30, 60, 90, 255 }, image.slice(0)[0..4]);

    const widest = try flatFavicon(favicon_worker.max_png_side, 1);
    defer gpa.free(widest);
    const at_side = try lookUpFavicon(widest);
    gpa.destroy(try at_side.result);
    try std.testing.expect(at_side.limit == null);

    // A header that declares the whole square passes the limit; its data
    // does not match it, so the decode fails as invalid, not as too large.
    const square = try png.declareForTest(gpa, widest, favicon_worker.max_png_side, favicon_worker.max_png_side);
    defer gpa.free(square);
    const declared = try lookUpFavicon(square);
    try std.testing.expectError(error.InvalidPngData, declared.result);
    try std.testing.expect(declared.limit == null);

    for ([_][2]u32{ .{ favicon_worker.max_png_side + 1, 1 }, .{ 1, favicon_worker.max_png_side + 1 } }) |size| {
        const oversized = try png.declareForTest(gpa, widest, size[0], size[1]);
        defer gpa.free(oversized);
        const refused = try lookUpFavicon(oversized);
        try std.testing.expectError(error.PngTooLarge, refused.result);
        const reach = refused.limit.?;
        try std.testing.expectEqualStrings("gui.favicons.max_png_side", reach.limit.name);
        try std.testing.expectEqual(@as(u64, favicon_worker.max_png_side), reach.limit.value);
        try std.testing.expectEqual(@as(?u64, favicon_worker.max_png_side + 1), reach.requested);
    }
}

test "a favicon past its PNG limit keeps the glyph and the window reports the limit" {
    const gpa = std.testing.allocator;
    var fixture = try ChromeFixture.init();
    defer fixture.deinit();
    const gui = fixture.session.gui;
    const widest = try flatFavicon(favicon_worker.max_png_side, 1);
    defer gpa.free(widest);
    const oversized = try png.declareForTest(gpa, widest, 2 * favicon_worker.max_png_side, 16);
    defer gpa.free(oversized);
    const workspace = Session.location.workspace.workspace;
    _ = try gui.app.model.workspace_list_snapshot.replace(.{ .revision = 1, .entries = &.{.{ .workspace = workspace, .name = "telar", .path = "/telar", .tab_count = 1 }} });
    const page = &gui.renderer.sprites.?;
    try std.testing.expect(gui.chrome.favicons.next(page, &gui.app.model.workspace_list_snapshot) != null);
    const job = client.favicons.request(
        &gui.app.model,
        .{
            .workspace = workspace,
            .cwd = "/telar",
            .cells = page.cells,
        },
    ).?;
    gui.chrome.favicons.started(workspace);

    // The completion lands on the window's loop, which reports what the
    // worker returned; the workspace keeps the glyph.
    var completion = try lookUpFavicon(oversized);
    completion.execution_id = job.execution_id;
    completion.workspace = workspace;
    try std.testing.expect(client.favicons.complete(gui.app, completion) == .missing);
    const reaches = &gui.app.model.limit_reaches;
    const slot = reaches.find("gui.favicons.max_png_side").?;
    try std.testing.expectEqual(@as(u64, 1), reaches.hits[slot]);
    try std.testing.expectEqual(@as(?u64, 2 * favicon_worker.max_png_side), reaches.requested[slot]);
    try std.testing.expect(!gui.app.model.favicons.busy());
    try std.testing.expect(gui.chrome.favicons.sprite(Session.location.workspace, .small) == null);
}

test "a workspace favicon reaches the card one frame after the worker completes" {
    const gpa = std.testing.allocator;
    const samples = [_]u8{ 255, 0, 0, 255 } ** 64;
    const bytes = try png.encodeForTest(gpa, .{ .header = .{ .width = 8, .height = 8, .color = .rgba }, .filter = 1 }, &samples);
    defer gpa.free(bytes);
    try expectFaviconCard(".telar/icon.png", bytes);
}

test "the reported root favicon.ico reaches the agent card through the worker inbox" {
    try expectFaviconCard("favicon.ico", imaging.testing.telar_ico);
}

test "a 16-bit RGB workspace favicon reaches the agent card through the worker inbox" {
    const gpa = std.testing.allocator;
    const samples = [_]u8{ 255, 255, 128, 32, 0, 64 } ** 64;
    const bytes = try png.encodeForTest(gpa, .{ .header = .{ .width = 8, .height = 8, .color = .rgb, .depth = 16 }, .filter = 4 }, &samples);
    defer gpa.free(bytes);
    try expectFaviconCard("favicon.png", bytes);
}

fn expectFaviconCard(name: []const u8, bytes: []const u8) !void {
    var fixture = try ChromeFixture.init();
    defer fixture.deinit();
    const session = fixture.session;
    const gui = session.gui;
    const renderer = &session.gui.renderer;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try temp.dir.realPath(io, &root_buffer)];
    try temp.dir.createDirPath(io, ".telar");
    try temp.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
    const workspace = Session.location.workspace.workspace;
    _ = try gui.app.model.workspace_list_snapshot.replace(.{ .revision = 1, .entries = &.{.{ .workspace = workspace, .name = "telar", .path = root, .tab_count = 1 }} });

    // The first preparation starts the lookup; its completion lands through
    // the inbox and the next preparation places the cell.
    const first = try session.draw();
    try std.testing.expect(gui.chrome.favicons.stateOf(workspace) == .pending);
    try std.testing.expect(gui.app.model.favicons.busy());
    try input_support.presented(
        gui,
        first,
        true,
    );
    var rounds: usize = 0;
    while (gui.chrome.favicons.stateOf(workspace) != .resolved) : (rounds += 1) {
        if (rounds == 8) {
            return error.FaviconNeverLanded;
        }

        // Presentation may have already consumed the worker completion. Prepare
        // first to adopt a ready image instead of waiting for another message.
        const token = try session.draw();
        try input_support.presented(
            gui,
            token,
            true,
        );
        if (gui.chrome.favicons.stateOf(workspace) == .resolved) {
            break;
        }

        if (gui.app.model.favicons.busy()) {
            try session.gui.driver.inbox.wait();
            _ = try gui.update();
        }
    }

    try std.testing.expect(!gui.app.model.favicons.busy());
    const placed = gui.chrome.favicons.sprite(Session.location.workspace, .small).?;
    try std.testing.expectEqual(SpritePage.provider_mark_count, placed.index);
    try std.testing.expectEqual(SpritePage.provider_mark_count + 1, renderer.sprites.?.count);
    renderer.seal();
    const version = renderer.sprites_version;
    const again = try session.draw();
    try input_support.presented(
        gui,
        again,
        true,
    );
    try std.testing.expectEqual(version, renderer.sprites_version);

    var agents: data.AgentSnapshot = .{};
    _ = try agents.replace(.{ .revision = 1, .agents = &.{agent(.claude, 51)} });
    var projection = fixture.projection();
    projection.agents = &agents;
    fixture.chrome.favicons = gui.chrome.favicons;
    try fixture.paint(projection);
    try std.testing.expectEqual(@as(usize, 3), spriteCount(renderer.quads.items()));
    var found = false;
    for (renderer.quads.items()) |item| {
        if (item.texture == quad.sprite_texture and item.u0 == renderer.sprites.?.uv(placed)[0] and item.v0 == renderer.sprites.?.uv(placed)[1]) {
            found = true;
        }
    }

    try std.testing.expect(found);
}
