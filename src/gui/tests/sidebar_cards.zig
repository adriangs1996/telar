//! Slice 4 of the GUI visual language: the sidebar header with counts, one
//! list ordered by attention and the three-row card in device pixels.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Fixture = @import("ChromeFixture.zig");
const Session = @import("Session.zig");
const Canvas = @import("../chrome/Canvas.zig");
const Context = @import("../chrome/Context.zig");
const HitMap = @import("../chrome/HitMap.zig");
const BandHitMap = @import("../chrome/BandHitMap.zig");
const AgentCard = @import("../chrome/AgentCard.zig");
const CardGeometry = @import("../chrome/CardGeometry.zig");
const Sidebar = @import("../chrome/Sidebar.zig");
const Level = @import("../chrome/card_degradation.zig").Level;
const Quad = @import("../render/Quad.zig").Quad;
const Rect = @import("../render/Rect.zig");

test {
    _ = @import("../chrome/age_label.zig");
    _ = @import("../chrome/status_glyph.zig");
    _ = @import("../chrome/card_degradation.zig");
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
    const renderer = &fixture.session.renderer;
    return renderer.metrics.rect(renderer.origin, fixture.chrome.presented().regions.sidebar);
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
    projection.sidebar_visible = true;
    try fixture.paint(projection);
    try std.testing.expectEqualSlices(u8, &expected_order, fixture.chrome.sidebar.ordering());
    const hits = &fixture.chrome.presented().hits;
    var position: usize = 0;
    var previous_bottom: u16 = 0;
    for (hits.items[0..hits.len]) |hit| {
        if (hit.action != .intent or hit.action.intent != .focus_agent) {
            continue;
        }

        try std.testing.expectEqualDeep(entries[expected_order[position]].key, hit.action.intent.focus_agent);
        try std.testing.expect(hit.area.y >= previous_bottom -| 1);
        previous_bottom = hit.area.y + hit.area.h;
        position += 1;
    }

    try std.testing.expectEqual(entries.len, position);
    try std.testing.expectEqual(@as(u16, 0), fixture.chrome.sidebar.maximum_scroll);
    try std.testing.expectEqualDeep(client.Intent{ .focus_agent = entries[5].key }, fixture.click(fixture.target(.{ .focus_agent = entries[5].key }).?, 0).intent);
}

test "the selected card is the focused pane's agent and carries the fill and ring" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var agents: client.AgentSnapshot = .{};
    _ = try agents.replace(.{ .revision = 1, .agents = &entries });
    var projection = fixture.projection();
    projection.agents = &agents;
    projection.sidebar_visible = true;
    try fixture.paint(projection);
    const quads = fixture.session.renderer.quads.items();
    try std.testing.expectEqual(@as(usize, 1), roundedCount(quads, CardGeometry.radius, sidebarColumn(&fixture)));
    try std.testing.expectEqual(@as(usize, entries.len), roundedCount(quads, 4, sidebarColumn(&fixture)));
    const selected = ring(quads).?;
    const renderer = &fixture.session.renderer;
    const sidebar = fixture.chrome.presented().regions.sidebar;
    const bounds = renderer.metrics.rect(renderer.origin, .{ .x = sidebar.x, .y = sidebar.y, .w = sidebar.w - 1, .h = sidebar.h });
    const geometry = CardGeometry.derive(renderer.metrics);
    const list_top = bounds.y + Sidebar.margin + geometry.row_height + Sidebar.header_gap;
    try std.testing.expectEqual(list_top + 5 * geometry.pitch(), selected.y);
    try std.testing.expectEqual(geometry.height(), selected.height);
    try std.testing.expectEqual(bounds.x + Sidebar.margin, selected.x);
    const hovered = fixture.target(.{ .focus_agent = entries[2].key }).?;
    _ = fixture.chrome.pointer(.{ .x = hovered.x, .y = hovered.y, .kind = .move });
    try fixture.paint(projection);
    try std.testing.expectEqual(@as(usize, 2), roundedCount(fixture.session.renderer.quads.items(), CardGeometry.radius, sidebarColumn(&fixture)));
}

test "card tokens leave from the right as the card narrows" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var agents: client.AgentSnapshot = .{};
    _ = try agents.replace(.{ .revision = 1, .agents = &entries });
    var projection = fixture.projection();
    projection.agents = &agents;
    const renderer = &fixture.session.renderer;
    var hits: HitMap = .{};
    var band_hits: BandHitMap = .{};
    var canvas: Canvas = .{ .atlas = &renderer.atlas.?, .quads = &renderer.quads, .metrics = renderer.metrics, .origin = renderer.origin, .theme = fixture.session.gui.theme };
    var context: Context = .{ .canvas = &canvas, .hits = &hits, .bands = &band_hits, .projection = &projection, .hovered = null };
    const geometry = CardGeometry.derive(renderer.metrics);
    const card: AgentCard = .{ .context = &context, .agent = &agents.slice()[4], .geometry = geometry, .age_s = 30 };
    var widths: [4]f32 = undefined;
    var previous: Level = .full;
    var width: f32 = 600;
    widths[0] = width;
    while (width > 0) : (width -= 1) {
        const level = try card.level(width);
        try std.testing.expect(@intFromEnum(level) >= @intFromEnum(previous));
        if (level != previous) {
            widths[@intFromEnum(level)] = width;
        }

        previous = level;
    }

    try std.testing.expectEqual(Level.no_event, previous);
    var counts: [4]usize = undefined;
    for (widths, 0..) |inner, index| {
        renderer.quads.clear();
        try card.paint(.{ .x = 100, .y = 100, .width = inner + 2 * CardGeometry.padding_x, .height = geometry.height() });
        counts[index] = renderer.quads.items().len;
        try std.testing.expectEqual(@as(usize, @intFromBool(index < 2)), roundedCount(renderer.quads.items(), 4, null));
    }

    try std.testing.expect(counts[0] > counts[1]);
    try std.testing.expect(counts[1] > counts[2]);
    try std.testing.expect(counts[2] > counts[3]);
}

test "the working pulse steps the status alpha from the animation frame" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var agents: client.AgentSnapshot = .{};
    _ = try agents.replace(.{ .revision = 1, .agents = &entries });
    var projection = fixture.projection();
    projection.agents = &agents;
    projection.sidebar_visible = true;
    projection.sidebar_animation_frame = 0;
    try fixture.paint(projection);
    for (fixture.session.renderer.quads.items()) |item| {
        try std.testing.expect(item.a == 1 or item.a == 0);
    }

    projection.sidebar_animation_frame = 9;
    try fixture.paint(projection);
    var dimmed: usize = 0;
    for (fixture.session.renderer.quads.items()) |item| {
        dimmed += @intFromBool(@abs(item.a - 0.35) < 0.001);
    }

    try std.testing.expect(dimmed > 0);
}

test "the snapshot arrival is retained until the revision changes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var agents: client.AgentSnapshot = .{};
    _ = try agents.replace(.{ .revision = 1, .agents = &entries });
    var projection = fixture.projection();
    projection.agents = &agents;
    projection.sidebar_visible = true;
    fixture.chrome.now_s = 100;
    try fixture.paint(projection);
    try std.testing.expectEqual(@as(u32, 100), fixture.chrome.sidebar.arrived_s);
    fixture.chrome.now_s = 400;
    try fixture.paint(projection);
    try std.testing.expectEqual(@as(u32, 100), fixture.chrome.sidebar.arrived_s);
    _ = try agents.replace(.{ .revision = 2, .agents = entries[0..2] });
    try fixture.paint(projection);
    try std.testing.expectEqual(@as(u32, 400), fixture.chrome.sidebar.arrived_s);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0 }, fixture.chrome.sidebar.ordering());
}

test "a warm sidebar repaint with six agents allocates nothing" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var agents: client.AgentSnapshot = .{};
    _ = try agents.replace(.{ .revision = 1, .agents = &entries });
    var projection = fixture.projection();
    projection.agents = &agents;
    projection.sidebar_visible = true;
    try fixture.paint(projection);
    const count = fixture.session.renderer.quads.items().len;
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
        projection.sidebar_animation_frame = @intCast(frame);
        fixture.chrome.now_s = @intCast(frame);
        try fixture.paint(projection);
    }

    try std.testing.expectEqual(count, fixture.session.renderer.quads.items().len);
    try std.testing.expectEqual(version, atlas.version);
    try std.testing.expectEqual(rasters, atlas.raster_attempts);
    try std.testing.expectEqual(@as(usize, 0), failure.allocations);
}

test "the hit map capacity is unchanged by the pixel sidebar" {
    try std.testing.expectEqual(core.max_panes_per_tab * 6 + core.max_agent_snapshot_entries * 3 + core.max_workspace_list_entries + core.max_tabs_per_workspace + 4, HitMap.capacity);
}
