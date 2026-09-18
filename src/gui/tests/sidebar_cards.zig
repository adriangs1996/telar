//! Slice 4 of the GUI visual language: the sidebar header, one
//! list ordered by attention and the three-row card in device pixels.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Fixture = @import("ChromeFixture.zig");
const Session = @import("Session.zig");
const Canvas = @import("../widgets/Canvas.zig");
const Context = @import("../widgets/Context.zig");
const HitMap = @import("../widgets/HitMap.zig");
const BandHitMap = @import("../widgets/BandHitMap.zig");
const AgentCard = @import("../widgets/AgentCard.zig");
const CardGeometry = @import("../widgets/CardGeometry.zig");
const Sidebar = @import("../widgets/Sidebar.zig");
const Quad = @import("../render/Quad.zig").Quad;
const Rect = @import("../render/Rect.zig");
const sprites = @import("sprites.zig");

test {
    _ = @import("../widgets/age_label.zig");
    _ = @import("../widgets/status_glyph.zig");
    _ = CardGeometry;
}

// Six agents across the four groups; the idle one sits in the fixture's
// focused pane so its card is the selected one.
const entries = [_]client.AgentInput{
    .{ .key = .{ .pane_id = Session.pane_id, .pane_generation = 1 }, .location = Session.location, .pane_index = 1, .provider = .claude, .status = .ready, .status_age_s = 10, .workspace_label = "telar", .session_title = "idle shell", .last_event = "done: tests green" },
    .{ .key = .{ .pane_id = @enumFromInt(52), .pane_generation = 1 }, .location = Session.location, .pane_index = 2, .provider = .codex, .status = .working, .status_age_s = 30, .workspace_label = "telar", .session_title = "fix proxy tests", .last_event = "\u{bb} Edit src/client/bars/Output.zig" },
    .{ .key = .{ .pane_id = @enumFromInt(53), .pane_generation = 1 }, .location = Session.location, .pane_index = 3, .provider = .claude, .status = .blocked, .blocked_reason = .permission, .status_age_s = 90, .workspace_label = "server", .session_title = "rotate the CA", .last_event = "Run zig build test?" },
    .{ .key = .{ .pane_id = @enumFromInt(54), .pane_generation = 1 }, .location = Session.location, .pane_index = 4, .provider = .pi, .status = .done, .status_age_s = 5, .workspace_label = "docs", .session_title = "write the sidebar note", .last_event = "Wrote docs/sidebar.md" },
    .{ .key = .{ .pane_id = @enumFromInt(55), .pane_generation = 1 }, .location = Session.location, .pane_index = 5, .provider = .codex, .status = .working, .status_age_s = 2, .workspace_label = "a-rather-long-workspace-name", .session_title = "a very long session title that will not fit inside one sidebar card row", .last_event = "\u{bb} Bash zig build test-gui" },
    .{ .key = .{ .pane_id = @enumFromInt(56), .pane_generation = 1 }, .location = Session.location, .pane_index = 6, .provider = .unknown, .status = .failed, .status_age_s = 20, .workspace_label = "perf", .session_title = "latency sweep", .last_event = "HTTP 500 from the provider" },
};

const expected_order = [_]u8{ 5, 2, 4, 1, 3, 0 };

// Counted inside the sidebar column when one is painted: the active tab and
// the chips of the pixel chrome round their corners with the same radii.
fn roundedCount(quads: []const Quad, radius: f32, column: ?Rect) usize {
    var count: usize = 0;
    for (quads) |item| {
        const inside = if (column) |bounds| item.x >= bounds.x and item.x < bounds.x + bounds.width else true;
        count += @intFromBool(inside and item.radius == radius and item.border == 0);
    }

    return count;
}

fn sidebarColumn(fixture: *Fixture) Rect {
    return fixture.band();
}

fn ring(quads: []const Quad) ?Quad {
    for (quads) |item| {
        if (item.radius == CardGeometry.radius and item.border == 1) {
            return item;
        }
    }

    return null;
}

test "the sidebar orders six agents by attention and maps one hit per card" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var agents: client.AgentSnapshot = .{};
    _ = try agents.replace(.{ .revision = 1, .agents = &entries });
    var projection = fixture.projection();
    projection.agents = &agents;
    try fixture.paint(projection);
    try std.testing.expectEqualSlices(u8, &expected_order, fixture.chrome.sidebar.ordering());
    const hits = &fixture.chrome.presented().band_hits;
    var position: usize = 0;
    var previous_bottom: f32 = 0;
    for (hits.items[0..hits.len]) |hit| {
        if (hit.action != .intent or hit.action.intent != .focus_agent) {
            continue;
        }

        try std.testing.expectEqualDeep(entries[expected_order[position]].key, hit.action.intent.focus_agent);
        try std.testing.expect(hit.area.y >= previous_bottom + CardGeometry.spacing);
        previous_bottom = hit.area.y + hit.area.height;
        position += 1;
    }

    try std.testing.expectEqual(entries.len, position);
    try std.testing.expectEqual(@as(u16, 0), fixture.chrome.sidebar.agents.maximum_scroll);
    try std.testing.expectEqualDeep(client.Intent{ .focus_agent = entries[5].key }, fixture.clickBand(fixture.bandTarget(.{ .focus_agent = entries[5].key }).?, 0).intent);
}

test "replacement sidebar widgets retain scrolling and clip their own card controls" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var agents: client.AgentSnapshot = .{};
    _ = try agents.replace(.{ .revision = 1, .agents = &entries });
    var projection = fixture.projection();
    projection.agents = &agents;
    const renderer = &fixture.session.renderer;
    var hits: HitMap = .{};
    var band_hits: BandHitMap = .{};
    const context: Context = .{ .hits = &hits, .bands = &band_hits, .projection = &projection, .hovered = null };
    var state: @import("../widgets/SidebarState.zig") = .{};
    var canvas: Canvas = .{ .atlas = &renderer.atlas.?, .quads = &renderer.quads, .metrics = renderer.metrics, .origin = renderer.origin, .theme = fixture.session.gui.theme, .chrome = renderer.chrome, .viewport = renderer.viewport, .sidebar = renderer.sidebar };
    const GenericWidgetList = @import("../widgets/GenericWidgetList.zig").Type;
    const List = GenericWidgetList(Sidebar, 1);
    const area: Rect = .{ .x = 0, .y = 0, .width = 284, .height = 160 };
    {
        var widgets: List = .{};
        try widgets.append(.{ .state = &state, .context = &context, .area = area });
        try widgets.draw(&canvas);
    }

    const first = band_hits.find(.{ .focus_agent = entries[expected_order[0]].key }).?;
    try std.testing.expectEqualSlices(u8, &expected_order, state.ordering());
    try std.testing.expect(state.agents.scrollBy(20));
    renderer.quads.clear();
    band_hits = .{};
    {
        var widgets: List = .{};
        try widgets.append(.{ .state = &state, .context = &context, .area = area });
        try widgets.draw(&canvas);
    }

    try std.testing.expectEqual(@as(u16, 20), state.agents.scroll);
    const clipped = band_hits.find(.{ .focus_agent = entries[expected_order[0]].key }).?;
    try std.testing.expectEqual(first.area.y, clipped.area.y);
    try std.testing.expectEqual(first.area.height - 20, clipped.area.height);
    var empty: client.AgentSnapshot = .{};
    _ = try empty.replace(.{ .revision = 1, .agents = &.{} });
    projection.agents = &empty;
    renderer.quads.clear();
    band_hits = .{};
    try (Sidebar{ .state = &state, .context = &context, .area = area }).draw(&canvas);
    try std.testing.expectEqual(@as(usize, 0), state.ordering().len);
    try std.testing.expectEqual(@as(u16, 0), state.agents.scroll);
    try std.testing.expectEqual(@as(u16, 0), state.agents.maximum_scroll);
    try std.testing.expect(band_hits.find(.{ .focus_agent = entries[expected_order[0]].key }) == null);
}

test "the selected card is the focused pane's agent and carries the fill and ring" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var agents: client.AgentSnapshot = .{};
    _ = try agents.replace(.{ .revision = 1, .agents = &entries });
    var projection = fixture.projection();
    projection.agents = &agents;
    try fixture.paint(projection);
    const quads = fixture.session.renderer.quads.items();
    try std.testing.expectEqual(@as(usize, 1), roundedCount(quads, CardGeometry.radius, sidebarColumn(&fixture)));
    // Provider marks are secondary; custom providers use an unboxed glyph.
    try std.testing.expectEqual(@as(usize, 0), roundedCount(quads, 4, sidebarColumn(&fixture)));
    try std.testing.expectEqual(@as(usize, 5), sprites.spriteCount(quads));
    const selected = ring(quads).?;
    const renderer = &fixture.session.renderer;
    const geometry = CardGeometry.derive(renderer.chrome, renderer.metrics);
    const list_top = fixture.chrome.presented().sidebar_regions.agents.y;
    try std.testing.expectEqual(list_top + 5 * geometry.pitch(), selected.y);
    try std.testing.expectEqual(geometry.height(), selected.height);
    try std.testing.expectEqual(fixture.band().x + Sidebar.margin, selected.x);
    const hovered = fixture.bandTarget(.{ .focus_agent = entries[2].key }).?;
    _ = fixture.chrome.bandPointer(.{ .kind = .move, .x = hovered.x, .y = hovered.y });
    try fixture.paint(projection);
    try std.testing.expectEqual(@as(usize, 2), roundedCount(fixture.session.renderer.quads.items(), CardGeometry.radius, sidebarColumn(&fixture)));
}

test "narrow cards keep status in the first row and clip every token to its card" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var agents: client.AgentSnapshot = .{};
    _ = try agents.replace(.{ .revision = 1, .agents = &entries });
    var projection = fixture.projection();
    projection.agents = &agents;
    const renderer = &fixture.session.renderer;
    var hits: HitMap = .{};
    var band_hits: BandHitMap = .{};
    var canvas: Canvas = .{ .atlas = &renderer.atlas.?, .quads = &renderer.quads, .metrics = renderer.metrics, .origin = renderer.origin, .theme = fixture.session.gui.theme, .chrome = renderer.chrome, .sprites = &renderer.sprites.? };
    const context: Context = .{ .hits = &hits, .bands = &band_hits, .projection = &projection, .hovered = null };
    const geometry = CardGeometry.derive(renderer.chrome, renderer.metrics);
    projection.sidebar_animation_frame = 9;
    for ([_]f32{ 300, 220, 120, 60, 24, 8, 0 }) |width| {
        renderer.quads.clear();
        const bounds: Rect = .{ .x = 100, .y = 100, .width = width, .height = geometry.height() };
        const card: AgentCard = .{ .context = &context, .bounds = bounds, .agent = &agents.slice()[4], .geometry = geometry, .age_s = 30 };
        try card.draw(&canvas);
        const first = geometry.row(bounds, 0);
        var pulsing = false;
        for (renderer.quads.items()) |item| {
            try std.testing.expect(item.x >= bounds.x and item.y >= bounds.y);
            try std.testing.expect(item.x + item.width <= bounds.x + bounds.width + 0.001);
            try std.testing.expect(item.y + item.height <= bounds.y + bounds.height + 0.001);
            if (@abs(item.a - 0.65) < 0.001) {
                try std.testing.expect(item.y >= first.y and item.y + item.height <= first.y + first.height);
                pulsing = true;
            }
        }

        if (width >= 60) {
            try std.testing.expect(pulsing);
        }
    }
}

test "card detail follows working state and the agent workspace across branch-only revisions" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var agents: client.AgentSnapshot = .{};
    var input = entries[1];
    const own_workspace = input.location.workspace.workspace;
    var workspaces: client.WorkspaceListSnapshot = .{};
    _ = try workspaces.replace(.{ .revision = 1, .entries = &.{
        .{ .workspace = @enumFromInt(900), .name = "other", .path = "/other", .tab_count = 1, .branch = "wrong-branch" },
        .{ .workspace = own_workspace, .name = "telar", .path = "/telar", .tab_count = 1, .branch = "feature/sidebar" },
    } });
    var projection = fixture.projection();
    projection.agents = &agents;
    projection.workspaces = &workspaces;
    const renderer = &fixture.session.renderer;
    var hits: HitMap = .{};
    var band_hits: BandHitMap = .{};
    const context: Context = .{ .hits = &hits, .bands = &band_hits, .projection = &projection, .hovered = null };
    var card: AgentCard = .{ .context = &context, .bounds = .{ .x = 0, .y = 0, .width = 0, .height = 0 }, .agent = undefined, .geometry = CardGeometry.derive(renderer.chrome, renderer.metrics), .age_s = 10 };
    for ([_]core.AgentStatus{ .working, .ready, .done, .blocked, .failed, .unknown }, 1..) |state, revision| {
        input.status = state;
        _ = try agents.replace(.{ .revision = revision, .agents = &.{input} });
        card.agent = &agents.slice()[0];
        try std.testing.expectEqualStrings(if (state == .working) input.last_event else "feature/sidebar", card.detailText());
    }

    _ = try workspaces.replace(.{ .revision = 2, .entries = &.{.{ .workspace = own_workspace, .name = "telar", .path = "/telar", .tab_count = 1, .branch = "main" }} });
    try std.testing.expectEqualStrings("main", card.detailText());
    _ = try workspaces.replace(.{ .revision = 3, .entries = &.{.{ .workspace = own_workspace, .name = "telar", .path = "/telar", .tab_count = 1 }} });
    try std.testing.expectEqualStrings("", card.detailText());
    _ = try workspaces.replace(.{ .revision = 4, .entries = &.{} });
    try std.testing.expectEqualStrings("", card.detailText());
    input.location.workspace = .{ .worktree = @enumFromInt(1) };
    _ = try agents.replace(.{ .revision = 7, .agents = &.{input} });
    try std.testing.expectEqualStrings("", card.detailText());
    input.status = .working;
    input.last_event = "";
    _ = try agents.replace(.{ .revision = 8, .agents = &.{input} });
    try std.testing.expectEqualStrings("", card.detailText());
}

test "the working pulse samples the status alpha from presentation time" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var agents: client.AgentSnapshot = .{};
    _ = try agents.replace(.{ .revision = 1, .agents = &entries });
    var projection = fixture.projection();
    projection.agents = &agents;
    fixture.chrome.now_ns = 0;
    try fixture.paint(projection);
    for (fixture.session.renderer.quads.items()) |item| {
        try std.testing.expect(item.a == 1 or item.a == 0 or item.a == AgentCard.provider_alpha);
    }

    fixture.chrome.now_ns = 9 * 120 * std.time.ns_per_ms;
    try fixture.paint(projection);
    var dimmed: usize = 0;
    for (fixture.session.renderer.quads.items()) |item| {
        dimmed += @intFromBool(@abs(item.a - 0.65) < 0.001);
    }

    try std.testing.expect(dimmed > 0);
}

test "sidebar clocks survive unrelated snapshot changes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var agents: client.AgentSnapshot = .{};
    _ = try agents.replace(.{ .revision = 1, .agents = &entries });
    var projection = fixture.projection();
    projection.agents = &agents;
    fixture.chrome.now_ns = 100 * std.time.ns_per_s;
    try fixture.paint(projection);
    try std.testing.expectEqual(@as(u32, 30), fixture.chrome.ages.seconds(&agents.slice()[1]));
    fixture.chrome.now_ns = 400 * std.time.ns_per_s;
    try fixture.paint(projection);
    try std.testing.expectEqual(@as(u32, 330), fixture.chrome.ages.seconds(&agents.slice()[1]));
    _ = try agents.replace(.{ .revision = 2, .agents = entries[0..2] });
    try fixture.paint(projection);
    try std.testing.expectEqual(@as(u32, 330), fixture.chrome.ages.seconds(&agents.slice()[1]));
    try std.testing.expectEqualSlices(u8, &.{ 1, 0 }, fixture.chrome.sidebar.ordering());
}

test "a snapshot refresh cannot rewind a working duration already painted" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var agents: client.AgentSnapshot = .{};
    var input = entries[0];
    input.status = .working;
    input.status_age_s = 5;
    _ = try agents.replace(.{ .revision = 1, .agents = &.{input} });
    var projection = fixture.projection();
    projection.agents = &agents;
    fixture.chrome.now_ns = 100 * std.time.ns_per_s;
    try fixture.paint(projection);
    fixture.chrome.now_ns = 101 * std.time.ns_per_s;
    try fixture.paint(projection);
    const visible = try std.testing.allocator.dupe(Quad, fixture.session.renderer.quads.items());
    defer std.testing.allocator.free(visible);

    _ = try agents.replace(.{ .revision = 2, .agents = &.{input} });
    try fixture.paint(projection);
    try std.testing.expectEqualDeep(visible, fixture.session.renderer.quads.items());
}

test "a warm sidebar repaint with six agents allocates nothing" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var agents: client.AgentSnapshot = .{};
    _ = try agents.replace(.{ .revision = 1, .agents = &entries });
    var projection = fixture.projection();
    projection.agents = &agents;
    var workspaces: client.WorkspaceListSnapshot = .{};
    _ = try workspaces.replace(.{ .revision = 1, .entries = &.{
        .{ .workspace = Session.location.workspace.workspace, .name = "telar", .path = "/sandbox/telar", .tab_count = 1 },
        .{ .workspace = @enumFromInt(8), .name = "a long project name that needs truncation", .path = "/work/a-long-workspace-path-that-needs-truncation", .tab_count = 1 },
    } });
    projection.workspaces = &workspaces;
    // Warm the changing seconds as well as the static labels and glyphs.
    for (0..60) |second| {
        fixture.chrome.now_ns = second * std.time.ns_per_s;
        try fixture.paint(projection);
    }

    const atlas = &fixture.session.renderer.atlas.?;
    const version = atlas.version;
    const rasters = atlas.raster_attempts;
    var failure = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const allocator = atlas.allocator;
    atlas.allocator = failure.allocator();
    defer atlas.allocator = allocator;
    const quad_allocator = fixture.session.renderer.quads.allocator;
    fixture.session.renderer.quads.allocator = failure.allocator();
    defer fixture.session.renderer.quads.allocator = quad_allocator;
    for (0..30) |frame| {
        fixture.chrome.now_ns = (60 + frame) * std.time.ns_per_s;
        try fixture.paint(projection);
    }

    try std.testing.expectEqual(version, atlas.version);
    try std.testing.expectEqual(rasters, atlas.raster_attempts);
    try std.testing.expectEqual(@as(usize, 0), failure.allocations);
}

test "the hit map capacity is unchanged by the pixel sidebar" {
    try std.testing.expectEqual(core.max_panes_per_tab * 6 + core.max_agent_snapshot_entries * 3 + core.max_workspace_list_entries + core.max_tabs_per_workspace + 4, HitMap.capacity);
}
