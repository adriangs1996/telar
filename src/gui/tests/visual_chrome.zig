//! Slice 5 of the GUI visual language: pixel chrome bands, the tab strip,
//! attention dots and rings, pane headers and the toast policy.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Fixture = @import("ChromeFixture.zig");
const Session = @import("Session.zig");
const Renderer = @import("../render/TerminalRenderer.zig");
const Canvas = @import("../chrome/Canvas.zig");
const Bands = @import("../chrome/Bands.zig");
const ChromeMetrics = @import("../chrome/ChromeMetrics.zig");
const TabStrip = @import("../chrome/TabStrip.zig");
const Overlays = @import("../overlays/Overlays.zig");
const Notifications = @import("../overlays/Notifications.zig");
const PaneDecorations = @import("../chrome/PaneDecorations.zig");
const Rect = @import("../render/Rect.zig");
const Quad = @import("../render/Quad.zig").Quad;

const second_tab: core.TabId = @enumFromInt(2);
const second_location: core.TabLocation = .{ .workspace = Session.location.workspace, .tab_id = second_tab };

test "chrome bands leave complete cells below them and share the pointer origin" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    for ([_]f32{ 1, 2 }) |scale| {
        const size = try renderer.measure(.{ .width = 1000, .height = 700, .scale = scale });
        const chrome = ChromeMetrics.resolve(renderer.config, scale);
        try std.testing.expectEqual(chrome, renderer.chrome);
        try std.testing.expectEqual([2]u32{ 0, chrome.top_bar + chrome.tab_strip }, renderer.origin);
        try std.testing.expect(chrome.vertical() + @as(u32, size.rows) * size.cell_height_px <= 700);
        try std.testing.expect(chrome.vertical() + @as(u32, size.rows + 1) * size.cell_height_px > 700);
        var quads = @import("../render/QuadList.zig").init(std.testing.allocator);
        defer quads.deinit();
        const canvas: Canvas = .{ .atlas = &renderer.atlas.?, .quads = &quads, .metrics = renderer.metrics, .origin = renderer.origin, .theme = client.theme_support.default_theme, .chrome = renderer.chrome, .viewport = renderer.viewport };
        const bands = Bands.resolve(&canvas, .{ .x = 10, .y = 0, .w = size.cols - 10, .h = size.rows });
        try std.testing.expectEqual(@as(f32, @floatFromInt(renderer.origin[1])), bands.tab_strip.y + bands.tab_strip.height);
        try std.testing.expectEqual(canvas.rect(.{ .x = 10, .y = 0, .w = 1, .h = 1 }).x, bands.tab_strip.x);
        try std.testing.expectEqual(bands.shoulder.width, bands.tab_strip.x);
        const grid_bottom = canvas.rect(.{ .x = 0, .y = size.rows - 1, .w = 1, .h = 1 });
        try std.testing.expect(grid_bottom.y + grid_bottom.height <= bands.status_bar.y);
        try std.testing.expect(!bands.contains(bands.tab_strip.x, @floatFromInt(renderer.origin[1])));
        try std.testing.expect(bands.contains(bands.tab_strip.x, bands.tab_strip.y));
    }

    // A window too short for a row plus its bands gives the bands back.
    const tiny = try renderer.measure(.{ .width = 300, .height = 40, .scale = 1 });
    try std.testing.expectEqual(@as(u16, @intCast(40 / renderer.metrics.cell_height)), tiny.rows);
    try std.testing.expect(tiny.rows >= 1);
    try std.testing.expectEqual(@as(u32, 0), renderer.chrome.vertical());
    try std.testing.expectEqual([2]u32{ 0, 0 }, renderer.origin);
}

test "tab strip hits keep stable tab identities and the plus creates a tab" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const tabs = &fixture.session.gui.app.model.workspace;
    _ = try tabs.addCreated(.{ .location = second_location, .position = 1, .label = "editor", .root_pane_id = @enumFromInt(20) }, fixture.session.gui.app.model.hostSize());
    _ = tabs.select(Session.location.tab_id);
    try fixture.paint(fixture.projection());
    const strip = fixture.chrome.presented().bands.tab_strip;
    const first = fixture.bandTarget(.{ .select_tab = Session.location.tab_id }).?;
    const second = fixture.bandTarget(.{ .select_tab = second_tab }).?;
    try std.testing.expect(first.x < second.x);
    try std.testing.expect(Bands.within(strip, first.x, first.y) and Bands.within(strip, second.x, second.y));
    try std.testing.expectEqualDeep(client.Intent{ .select_tab = second_tab }, fixture.clickBand(second, 0).intent);
    try std.testing.expectEqualDeep(client.Intent{ .rename_tab = second_tab }, fixture.clickBand(second, 2).intent);
    try std.testing.expect(fixture.clickBand(second, 1).intent == .none);
    const plus = fixture.bandTarget(.create_tab).?;
    try std.testing.expect(plus.x > second.x + second.width);
    try std.testing.expectEqualDeep(client.Intent.create_tab, fixture.clickBand(plus, 0).intent);
    try std.testing.expect(fixture.chrome.band_gesture == null);

    // A press keeps the band gesture through a drag over cells until release.
    const press = fixture.chrome.bandPointer(.{ .kind = 6, .code = 1, .x = first.x, .y = first.y }).?;
    try std.testing.expect(press.consumed and press.intent == .select_tab);
    try std.testing.expect(fixture.chrome.bandPointer(.{ .kind = 6, .code = 3, .x = 5, .y = 5000 }).?.consumed);
    try std.testing.expect(fixture.chrome.bandPointer(.{ .kind = 6, .code = 2, .x = 5, .y = 5000 }).?.consumed);
    try std.testing.expect(fixture.chrome.band_gesture == null);
    try std.testing.expect(fixture.chrome.bandPointer(.{ .kind = 6, .code = 6, .x = 5, .y = 5000 }) == null);
    const widths = [_]f32{ 100, 100, 100 };
    try std.testing.expectEqual(@as(usize, 1), TabStrip.firstVisible(2, &widths, .{ .available = 210, .gap = 5 }));
    try std.testing.expectEqual(@as(usize, 0), TabStrip.firstVisible(2, &widths, .{ .available = 310, .gap = 5 }));
    try std.testing.expectEqual(@as(usize, 2), TabStrip.firstVisible(2, &widths, .{ .available = 150, .gap = 5 }));
}

fn blockedAgents(location: core.TabLocation, status: core.AgentStatus) !client.AgentSnapshot {
    var agents: client.AgentSnapshot = .{};
    _ = try agents.replace(.{ .revision = 1, .agents = &.{
        .{ .key = .{ .pane_id = @enumFromInt(20), .pane_generation = 1 }, .location = location, .pane_index = 1, .provider = .claude, .status = status, .blocked_reason = .permission, .status_age_s = 30, .display_name = "Claude" },
        .{ .key = .{ .pane_id = Session.pane_id, .pane_generation = 1 }, .location = Session.location, .pane_index = 1, .provider = .codex, .status = .working, .status_age_s = 250, .display_name = "Codex" },
    } });
    return agents;
}

fn dotQuads(quads: []const Quad, bounds: Rect, color: core.Color) usize {
    var count: usize = 0;
    for (quads) |quad| {
        const rounded = quad.radius > 0 and quad.width == quad.height and quad.width <= 8;
        const inside = quad.x >= bounds.x and quad.y >= bounds.y and quad.x + quad.width <= bounds.x + bounds.width and quad.y + quad.height <= bounds.y + bounds.height;
        if (rounded and inside and matchesColor(quad, color)) {
            count += 1;
        }
    }

    return count;
}

fn matchesColor(quad: Quad, color: core.Color) bool {
    const rgb = color.rgb;
    return @abs(quad.r - @as(f32, @floatFromInt(rgb[0])) / 255) < 0.01 and @abs(quad.g - @as(f32, @floatFromInt(rgb[1])) / 255) < 0.01 and @abs(quad.b - @as(f32, @floatFromInt(rgb[2])) / 255) < 0.01;
}

test "a blocked agent puts a dot on its tab and on its workspace pill" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const tabs = &fixture.session.gui.app.model.workspace;
    _ = try tabs.addCreated(.{ .location = second_location, .position = 1, .label = "editor", .root_pane_id = @enumFromInt(20) }, fixture.session.gui.app.model.hostSize());
    _ = tabs.select(Session.location.tab_id);
    var workspaces: client.WorkspaceListSnapshot = .{};
    _ = try workspaces.replace(.{ .revision = 1, .entries = &.{
        .{ .workspace = Session.location.workspace.workspace, .name = "telar", .path = "/telar", .tab_count = 2 },
        .{ .workspace = @enumFromInt(9), .name = "server", .path = "/server", .tab_count = 1 },
    } });
    var agents = try blockedAgents(second_location, .blocked);
    var projection = fixture.projection();
    projection.workspaces = &workspaces;
    projection.agents = &agents;
    try fixture.paint(projection);
    const palette = fixture.session.gui.theme.palette;
    const quads = fixture.session.renderer.quads.items();
    const blocked_tab = fixture.bandTarget(.{ .select_tab = second_tab }).?;
    const working_tab = fixture.bandTarget(.{ .select_tab = Session.location.tab_id }).?;
    try std.testing.expectEqual(@as(usize, 1), dotQuads(quads, blocked_tab, palette.yellow));
    try std.testing.expectEqual(@as(usize, 0), dotQuads(quads, working_tab, palette.yellow));
    const pill = fixture.bandTarget(.{ .select_workspace = Session.location.workspace.workspace }).?;
    const other = fixture.bandTarget(.{ .select_workspace = @enumFromInt(9) }).?;
    try std.testing.expectEqual(@as(usize, 1), dotQuads(quads, pill, palette.yellow));
    try std.testing.expectEqual(@as(usize, 0), dotQuads(quads, other, palette.yellow));

    // Failed wins the red dot; working alone shows nothing.
    var failed = try blockedAgents(second_location, .failed);
    projection.agents = &failed;
    try fixture.paint(projection);
    try std.testing.expectEqual(@as(usize, 1), dotQuads(fixture.session.renderer.quads.items(), fixture.bandTarget(.{ .select_tab = second_tab }).?, palette.red));
    var working = try blockedAgents(second_location, .working);
    projection.agents = &working;
    try fixture.paint(projection);
    try std.testing.expectEqual(@as(usize, 0), dotQuads(fixture.session.renderer.quads.items(), fixture.bandTarget(.{ .select_tab = second_tab }).?, palette.teal));
}

fn ringQuads(quads: []const Quad, outer: Rect) usize {
    var count: usize = 0;
    for (quads) |quad| {
        if (quad.border == 2 and quad.a == 0 and quad.x == outer.x + 1 and quad.y == outer.y + 1 and quad.width == outer.width - 2) {
            count += 1;
        }
    }

    return count;
}

test "the attention ring surrounds an unfocused blocked pane only and the header carries its chip" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const model = fixture.session.gui.app.model.activeTabModel().?;
    const second: core.PaneId = @enumFromInt(20);
    try model.split(.{ .existing_pane = Session.pane_id, .new_pane = second, .location = Session.location, .axis = .horizontal, .area = fixture.projection().geometry.area });
    _ = model.layout.focusPane(Session.pane_id);
    var agents = try blockedAgents(Session.location, .blocked);
    var projection = fixture.projection();
    projection.agents = &agents;
    try fixture.paint(projection);
    var layout: client.LayoutSnapshot = .{};
    model.layout.snapshot(projection.geometry.area, &layout);
    const renderer = &fixture.session.renderer;
    const blocked_outer = renderer.metrics.rect(renderer.origin, layout.find(second).?.outer);
    const focused_outer = renderer.metrics.rect(renderer.origin, layout.find(Session.pane_id).?.outer);
    try std.testing.expectEqual(@as(usize, 1), ringQuads(renderer.quads.items(), blocked_outer));
    try std.testing.expectEqual(@as(usize, 0), ringQuads(renderer.quads.items(), focused_outer));
    const dim = renderer.metrics.rect(renderer.origin, layout.find(second).?.content);
    var dimmed = false;
    for (renderer.quads.items()) |quad| {
        dimmed = dimmed or (quad.x == dim.x and quad.y == dim.y and quad.width == dim.width and quad.height == dim.height and quad.a == PaneDecorations.dim_alpha);
    }

    try std.testing.expect(dimmed);
    var chip = false;
    const header = renderer.metrics.rect(renderer.origin, layout.find(second).?.outer.row(0));
    const yellow = fixture.session.gui.theme.palette.yellow;
    for (renderer.quads.items()) |quad| {
        chip = chip or (quad.radius == 4 and quad.y >= header.y and quad.y + quad.height <= header.y + header.height and matchesColor(quad, yellow));
    }

    try std.testing.expect(chip);

    _ = model.layout.focusPane(second);
    projection = fixture.projection();
    projection.agents = &agents;
    try fixture.paint(projection);
    try std.testing.expectEqual(@as(usize, 0), ringQuads(renderer.quads.items(), blocked_outer));
    try std.testing.expectEqual(@as(usize, 0), ringQuads(renderer.quads.items(), focused_outer));
}

test "toasts cap at two and skip a pane already on screen" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const model = &fixture.session.gui.app.model;
    for ([_][]const u8{ "One", "Two", "Three", "Four" }) |title| {
        _ = model.publishNotification(0, .{ .title = title, .message = "done", .target = .{ .focus_pane = @enumFromInt(999) } });
    }

    _ = model.advanceNotifications(client.transition_duration_ns);
    var overlays: Overlays = .{};
    const renderer = &fixture.session.renderer;
    var canvas: Canvas = .{ .atlas = &renderer.atlas.?, .quads = &renderer.quads, .metrics = renderer.metrics, .origin = renderer.origin, .theme = fixture.session.gui.theme, .chrome = renderer.chrome, .viewport = renderer.viewport };
    renderer.quads.clear();
    try overlays.paint(&canvas, fixture.projection());
    try std.testing.expectEqual(@as(usize, Notifications.max_visible * 2), overlays.prepared().notifications.count);

    _ = model.dismissNotification(model.notification_center.itemAt(0).?.id, client.transition_duration_ns);
    _ = model.dismissNotification(model.notification_center.itemAt(1).?.id, client.transition_duration_ns);
    _ = model.dismissNotification(model.notification_center.itemAt(2).?.id, client.transition_duration_ns);
    _ = model.advanceNotifications(client.transition_duration_ns * 3);
    _ = model.publishNotification(client.transition_duration_ns * 3, .{ .title = "Seen", .message = "visible pane", .target = .{ .focus_pane = Session.pane_id } });
    _ = model.advanceNotifications(client.transition_duration_ns * 4);
    renderer.quads.clear();
    try overlays.paint(&canvas, fixture.projection());
    try std.testing.expectEqual(@as(usize, 2), overlays.prepared().notifications.count);
    try std.testing.expect(Notifications.targetVisible(fixture.projection(), .{ .focus_pane = Session.pane_id }));
    try std.testing.expect(!Notifications.targetVisible(fixture.projection(), .{ .focus_pane = @enumFromInt(999) }));
    try std.testing.expect(!Notifications.targetVisible(fixture.projection(), .{ .select_tab = Session.location.tab_id }));
}

test "warm chrome with rings chips dots and toasts allocates and shapes nothing" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.resize(160, 50);
    const model = fixture.session.gui.app.model.activeTabModel().?;
    const second: core.PaneId = @enumFromInt(20);
    try model.split(.{ .existing_pane = Session.pane_id, .new_pane = second, .location = Session.location, .axis = .vertical, .area = fixture.projection().geometry.area });
    _ = model.layout.focusPane(Session.pane_id);
    var workspaces: client.WorkspaceListSnapshot = .{};
    _ = try workspaces.replace(.{ .revision = 1, .entries = &.{
        .{ .workspace = Session.location.workspace.workspace, .name = "telar", .path = "/Users/me/sandbox/telar", .branch = "main", .tab_count = 1 },
    } });
    fixture.chrome.home.set("/Users/me");
    var agents = try blockedAgents(Session.location, .blocked);
    var projection = fixture.projection();
    projection.workspaces = &workspaces;
    projection.agents = &agents;
    projection.sidebar_visible = true;
    // Warm both animation parities: the sidebar card alternates its glyph.
    for (0..2) |frame| {
        projection.sidebar_animation_frame = @intCast(frame);
        try fixture.paint(projection);
    }

    const atlas = &fixture.session.renderer.atlas.?;
    const version = atlas.version;
    const calls = atlas.shape_calls;
    const count = fixture.session.renderer.quads.items().len;
    var failure = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = atlas.allocator;
    atlas.allocator = failure.allocator();
    defer atlas.allocator = allocator;
    const quad_allocator = fixture.session.renderer.quads.allocator;
    fixture.session.renderer.quads.allocator = failure.allocator();
    defer fixture.session.renderer.quads.allocator = quad_allocator;
    for (0..60) |frame| {
        projection.sidebar_animation_frame = @intCast(frame);
        try fixture.paint(projection);
    }

    try std.testing.expectEqual(version, atlas.version);
    try std.testing.expectEqual(calls, atlas.shape_calls);
    try std.testing.expectEqual(count, fixture.session.renderer.quads.items().len);
    try std.testing.expectEqual(@as(usize, 0), failure.allocations);
}
