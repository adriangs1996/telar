const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Fixture = @import("ChromeFixture.zig");
const Session = @import("Session.zig");
const Quad = @import("../render/Quad.zig").Quad;
const Rect = @import("../render/Rect.zig");
const Canvas = @import("../widgets/Canvas.zig");
const Label = @import("../widgets/Label.zig");

test "native workspace labels center their text advance and clip long names inside each slot" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var workspaces: client.WorkspaceListSnapshot = .{};
    _ = try workspaces.replace(.{ .revision = 1, .entries = &.{
        .{ .workspace = Session.location.workspace.workspace, .name = "a", .path = "/a", .tab_count = 1 },
        .{ .workspace = @enumFromInt(9), .name = "a deliberately long workspace name", .path = "/long", .tab_count = 1 },
        .{ .workspace = @enumFromInt(30), .name = "xy", .path = "/xy", .tab_count = 1 },
    } });
    var projection = fixture.projection();
    projection.workspaces = &workspaces;
    try fixture.paint(projection);
    const labels = [_][]const u8{ "1 a", "2 a deliberately long workspace name", "3 xy" };
    for (labels, 0..) |text, index| {
        const bounds = fixture.bandTarget(.{ .select_workspace = workspaces.workspaceAt(index) }).?;
        try expectCenteredLabel(&fixture, bounds, .{ .text = text, .bold = index == 0, .face = .sans, .size = .body });
    }

    const active = fixture.bandTarget(.{ .select_workspace = Session.location.workspace.workspace }).?;
    const before_dot = try firstInk(fixture.session.renderer.quads.items(), active);
    var agents: client.AgentSnapshot = .{};
    _ = try agents.replace(.{ .revision = 1, .agents = &.{.{ .key = .{ .pane_id = Session.pane_id, .pane_generation = 1 }, .location = Session.location, .pane_index = 1, .provider = .codex, .status = .blocked }} });
    projection.agents = &agents;
    try fixture.paint(projection);
    const with_dot = try firstInk(fixture.session.renderer.quads.items(), active);
    try std.testing.expectApproxEqAbs(before_dot.x, with_dot.x, 0.01);
}

test "native workspace overflow counters keep nearest hidden destinations without normal or hover backgrounds" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var workspaces: client.WorkspaceListSnapshot = .{};
    _ = try workspaces.replace(.{ .revision = 1, .entries = &.{
        .{ .workspace = @enumFromInt(4), .name = "one", .path = "/one", .tab_count = 1 },
        .{ .workspace = @enumFromInt(8), .name = "two", .path = "/two", .tab_count = 1 },
        .{ .workspace = @enumFromInt(15), .name = "three", .path = "/three", .tab_count = 1 },
        .{ .workspace = Session.location.workspace.workspace, .name = "four", .path = "/four", .tab_count = 1 },
        .{ .workspace = @enumFromInt(23), .name = "five", .path = "/five", .tab_count = 1 },
        .{ .workspace = @enumFromInt(42), .name = "six", .path = "/six", .tab_count = 1 },
        .{ .workspace = @enumFromInt(99), .name = "seven", .path = "/seven", .tab_count = 1 },
    } });
    var projection = fixture.projection();
    projection.workspaces = &workspaces;
    for ([_]core.WorkspaceId{ @enumFromInt(8), @enumFromInt(42) }) |id| {
        for ([_]bool{ false, true }) |hovered| {
            fixture.chrome.hovered = if (hovered) .{ .intent = .{ .select_workspace = id } } else null;
            try fixture.paint(projection);
            const bounds = fixture.bandTarget(.{ .select_workspace = id }).?;
            _ = try firstInk(fixture.session.renderer.quads.items(), bounds);
            for (fixture.session.renderer.quads.items()) |quad| {
                if (quad.x >= bounds.x and quad.y >= bounds.y and quad.x + quad.width <= bounds.x + bounds.width and quad.y + quad.height <= bounds.y + bounds.height) {
                    try std.testing.expect(!solid(quad));
                }
            }

            try std.testing.expectEqualDeep(client.Intent{ .select_workspace = id }, fixture.clickBand(bounds, 0).intent);
        }
    }
}

test "native workspace visibility ignores the inherited collapse flag in wide and narrow windows" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const model = &fixture.session.gui.app.model;
    _ = try model.reconcileWorkspaceList(.{ .revision = 1, .entries = &.{
        .{ .workspace = Session.location.workspace.workspace, .name = "telar", .path = "/telar", .tab_count = 1 },
        .{ .workspace = @enumFromInt(9), .name = "freya", .path = "/freya", .tab_count = 1 },
        .{ .workspace = @enumFromInt(30), .name = "configs", .path = "/configs", .tab_count = 1 },
    } });
    const identities = [_]core.WorkspaceId{ Session.location.workspace.workspace, @enumFromInt(9), @enumFromInt(30) };
    for ([_]u32{ 2048, 320 }) |width| {
        try fixture.measure(.{ .width = width, .height = 700, .scale = 1 });
        var projection = fixture.projection();
        projection.workspace_list_collapsed = false;
        try fixture.paint(projection);
        var expected: [identities.len]?Rect = undefined;
        for (identities, 0..) |id, index| {
            expected[index] = fixture.bandTarget(.{ .select_workspace = id });
        }

        try std.testing.expect(expected[0] != null);
        try std.testing.expectEqual(width == 2048, expected[1] != null);
        try std.testing.expectEqual(width == 2048, expected[2] != null);
        projection.workspace_list_collapsed = true;
        try fixture.paint(projection);
        for (identities, expected) |id, bounds| {
            try std.testing.expectEqualDeep(bounds, fixture.bandTarget(.{ .select_workspace = id }));
        }

        var visible: usize = 0;
        const hits = fixture.chrome.presented().band_hits;
        for (hits.items[0..hits.len]) |hit| {
            if (hit.action == .intent and hit.action.intent == .select_workspace) {
                visible += 1;
            }
        }

        try std.testing.expectEqual(@as(usize, if (width == 2048) 3 else 1), visible);
        try std.testing.expect(fixture.bandTarget(.toggle_workspace_list) == null);
    }
}

test "native navigation names unlisted workspaces and worktrees without selecting unrelated entries" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const tabs = try std.testing.allocator.create(client.TabsModel);
    defer std.testing.allocator.destroy(tabs);
    tabs.* = client.TabsModel.init(std.testing.allocator);
    defer tabs.deinit();
    var workspaces: client.WorkspaceListSnapshot = .{};
    _ = try workspaces.replace(.{ .revision = 1, .entries = &.{
        .{ .workspace = @enumFromInt(1), .name = "unrelated workspace", .path = "/other", .tab_count = 1 },
        .{ .workspace = @enumFromInt(2), .name = "another workspace", .path = "/another", .tab_count = 1 },
    } });
    const renderer = &fixture.session.renderer;
    for ([_]core.WorkspaceLocation{ .{ .worktree = @enumFromInt(1) }, .{ .workspace = @enumFromInt(99) } }) |location| {
        try tabs.replaceWithRoot(.{ .pane_id = Session.pane_id, .location = .{ .workspace = location, .tab_id = Session.location.tab_id }, .size = fixture.session.gui.app.model.hostSize() });
        try tabs.reconcileWorkspace(.{ .workspace = location, .name = "current context", .tabs = &.{.{ .tab_id = Session.location.tab_id, .label = "main", .pane_count = 1 }} });
        var projection = fixture.projection();
        projection.tabs = tabs;
        try fixture.paint(projection);
        const top = fixture.chrome.presented().bands.top_bar;
        var empty_snapshot = try quadsIn(renderer.quads.items(), top);
        defer empty_snapshot.deinit(std.testing.allocator);

        projection.workspaces = &workspaces;
        try fixture.paint(projection);
        var unrelated_snapshot = try quadsIn(renderer.quads.items(), top);
        defer unrelated_snapshot.deinit(std.testing.allocator);
        try std.testing.expectEqualDeep(empty_snapshot.items, unrelated_snapshot.items);
        const hits = fixture.chrome.presented().band_hits;
        for (hits.items[0..hits.len]) |hit| {
            try std.testing.expect(hit.action != .intent or hit.action.intent != .select_workspace);
        }

        try std.testing.expect(fixture.bandTarget(.{ .select_tab = Session.location.tab_id }) != null);
    }
}

test "native workspace window keeps the active workspace centered with three global identities" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var workspaces: client.WorkspaceListSnapshot = .{};
    _ = try workspaces.replace(.{ .revision = 1, .entries = &.{
        .{ .workspace = @enumFromInt(4), .name = "one", .path = "/one", .tab_count = 1 },
        .{ .workspace = @enumFromInt(8), .name = "two", .path = "/two", .tab_count = 1 },
        .{ .workspace = @enumFromInt(15), .name = "three with a long name", .path = "/three", .tab_count = 1 },
        .{ .workspace = @enumFromInt(16), .name = "four", .path = "/four", .tab_count = 1 },
        .{ .workspace = @enumFromInt(23), .name = "five", .path = "/five", .tab_count = 1 },
        .{ .workspace = @enumFromInt(42), .name = "six", .path = "/six", .tab_count = 1 },
        .{ .workspace = @enumFromInt(99), .name = "seven", .path = "/seven", .tab_count = 1 },
    } });
    const tabs = try std.testing.allocator.create(client.TabsModel);
    defer std.testing.allocator.destroy(tabs);
    tabs.* = client.TabsModel.init(std.testing.allocator);
    defer tabs.deinit();
    var center: ?Rect = null;
    for (1..workspaces.count - 1) |index| {
        const active_id = workspaces.workspaceAt(index);
        try tabs.replaceWithRoot(.{ .pane_id = Session.pane_id, .location = .{ .workspace = .{ .workspace = active_id }, .tab_id = Session.location.tab_id }, .size = fixture.session.gui.app.model.hostSize() });
        var projection = fixture.projection();
        projection.tabs = tabs;
        projection.workspaces = &workspaces;
        try fixture.paint(projection);
        const previous = fixture.bandTarget(.{ .select_workspace = workspaces.workspaceAt(index - 1) }).?;
        const active = fixture.bandTarget(.{ .select_workspace = active_id }).?;
        const next = fixture.bandTarget(.{ .select_workspace = workspaces.workspaceAt(index + 1) }).?;
        try std.testing.expectEqual(previous.width, active.width);
        try std.testing.expectEqual(next.width, active.width);
        try std.testing.expectApproxEqAbs(active.x - previous.x, next.x - active.x, 0.01);
        try std.testing.expectEqualDeep(client.Intent{ .select_workspace = active_id }, fixture.clickBand(active, 0).intent);
        if (center) |bounds| {
            try std.testing.expectEqualDeep(bounds, active);
        }

        center = active;
        var slots: usize = 0;
        const hits = fixture.chrome.presented().band_hits;
        for (hits.items[0..hits.len]) |hit| {
            if (hit.action == .intent and hit.action.intent == .select_workspace and hit.area.width == active.width) {
                slots += 1;
            }
        }

        try std.testing.expectEqual(@as(usize, 3), slots);
        projection.workspace_list_collapsed = true;
        try fixture.paint(projection);
        try std.testing.expectEqualDeep(previous, fixture.bandTarget(.{ .select_workspace = workspaces.workspaceAt(index - 1) }).?);
        try std.testing.expectEqualDeep(active, fixture.bandTarget(.{ .select_workspace = active_id }).?);
        try std.testing.expectEqualDeep(next, fixture.bandTarget(.{ .select_workspace = workspaces.workspaceAt(index + 1) }).?);
        try std.testing.expect(fixture.bandTarget(.toggle_workspace_list) == null);
    }
}

test "native workspaces and tabs occupy opposite ends of one row independent of sidebar visibility" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const model = &fixture.session.gui.app.model;
    _ = try model.reconcileWorkspaceList(.{ .revision = 1, .entries = &.{
        .{ .workspace = Session.location.workspace.workspace, .name = "telar", .path = "/telar", .tab_count = 2 },
        .{ .workspace = @enumFromInt(9), .name = "server", .path = "/server", .tab_count = 1 },
        .{ .workspace = @enumFromInt(30), .name = "config", .path = "/config", .tab_count = 1 },
    } });
    _ = try model.workspace.addCreated(.{ .location = .{ .workspace = Session.location.workspace, .tab_id = @enumFromInt(2) }, .position = 1, .label = "editor", .root_pane_id = @enumFromInt(20) }, model.hostSize());

    for ([_]u32{ 900, 1600 }) |width| {
        try fixture.measure(.{ .width = width, .height = 700, .scale = 1 });
        try fixture.showSidebar(true);
        try fixture.paint(fixture.projection());
        const top = fixture.chrome.presented().bands.top_bar;
        const workspace = fixture.bandTarget(.{ .select_workspace = Session.location.workspace.workspace }).?;
        const first_tab = fixture.bandTarget(.{ .select_tab = Session.location.tab_id }).?;
        const second_tab = fixture.bandTarget(.{ .select_tab = @enumFromInt(2) }).?;
        const plus = fixture.bandTarget(.create_tab).?;
        try std.testing.expectEqual(@as(f32, 42), top.height);
        try std.testing.expectEqual(@as(u32, 42), fixture.session.renderer.origin[1]);
        try std.testing.expect(workspace.x + workspace.width < first_tab.x);
        try std.testing.expect(first_tab.x > top.width / 2);
        try std.testing.expect(first_tab.x + first_tab.width <= second_tab.x);
        try std.testing.expect(second_tab.x + second_tab.width <= plus.x);
        try std.testing.expect(top.width - (plus.x + plus.width) <= 12);
        try std.testing.expect(workspace.y < top.height and first_tab.y < top.height);
        try std.testing.expectEqual(top.height, second_tab.y + second_tab.height);

        try fixture.showSidebar(false);
        try fixture.paint(fixture.projection());
        try std.testing.expectEqualDeep(workspace, fixture.bandTarget(.{ .select_workspace = Session.location.workspace.workspace }).?);
        try std.testing.expectEqualDeep(first_tab, fixture.bandTarget(.{ .select_tab = Session.location.tab_id }).?);
        try std.testing.expectEqualDeep(second_tab, fixture.bandTarget(.{ .select_tab = @enumFromInt(2) }).?);
        try std.testing.expectEqualDeep(plus, fixture.bandTarget(.create_tab).?);
    }
}

test "native active tab remains reachable after long preceding labels at narrow window widths" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const model = &fixture.session.gui.app.model;
    const tabs = &model.workspace;
    _ = try model.reconcileWorkspaceList(.{ .revision = 1, .entries = &.{
        .{ .workspace = Session.location.workspace.workspace, .name = "a workspace with a long name", .path = "/one", .tab_count = 8 },
        .{ .workspace = @enumFromInt(2), .name = "another workspace with a long name", .path = "/two", .tab_count = 1 },
        .{ .workspace = @enumFromInt(3), .name = "third workspace with a long name", .path = "/three", .tab_count = 1 },
    } });
    _ = try tabs.applyLabel(Session.location.tab_id, "first tab with a deliberately long label");
    for (1..8) |index| {
        _ = try tabs.addCreated(.{ .location = .{ .workspace = Session.location.workspace, .tab_id = @enumFromInt(index + 1) }, .position = @intCast(index), .label = "another tab with a deliberately long label", .root_pane_id = @enumFromInt(index + 20) }, model.hostSize());
    }

    try fixture.showSidebar(false);
    for ([_]u32{ 120, 240, 480, 900 }) |width| {
        try fixture.measure(.{ .width = width, .height = 500, .scale = 1 });
        for ([_]core.TabId{ @enumFromInt(8), @enumFromInt(4), Session.location.tab_id }) |active| {
            _ = tabs.select(active);
            try fixture.paint(fixture.projection());
            const hit = fixture.bandTarget(.{ .select_tab = active }) orelse return error.ActiveTabHidden;
            try std.testing.expect(hit.width > 0 and hit.height > 0);
            try std.testing.expect(hit.x >= 0 and hit.x + hit.width <= @as(f32, @floatFromInt(width)));
            try std.testing.expectEqualDeep(client.Intent{ .select_tab = active }, fixture.clickBand(hit, 0).intent);
            try std.testing.expectEqualDeep(client.Intent{ .rename_tab = active }, fixture.clickBand(hit, 2).intent);
            try std.testing.expect(fixture.chrome.band_gesture == null);
        }
    }
}

test "native selected tab has a rounded surface and only explicit child progress adds a stripe" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.paint(fixture.projection());
    const renderer = &fixture.session.renderer;
    const top = fixture.chrome.presented().bands.top_bar;
    const selected = fixture.bandTarget(.{ .select_tab = Session.location.tab_id }).?;
    var rounded = false;
    for (renderer.quads.items()) |quad| {
        if (quad.radius > 0 and quad.x >= selected.x and quad.x + quad.width <= selected.x + selected.width and quad.y >= selected.y and quad.y + quad.height <= selected.y + selected.height and quad.width > quad.height) {
            rounded = true;
        }
    }

    try std.testing.expect(rounded);
    var before = try quadsIn(renderer.quads.items(), top);
    defer before.deinit(std.testing.allocator);
    const pane = fixture.session.gui.app.model.workspace.findPane(Session.pane_id).?;
    _ = pane.setProgress(.{ .pane_id = Session.pane_id, .state = .set, .percent = 50 });
    try fixture.paint(fixture.projection());
    var after = try quadsIn(renderer.quads.items(), top);
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqual(before.items.len + 1, after.items.len);
    var original: usize = 0;
    var added: ?Quad = null;
    for (after.items) |quad| {
        if (original < before.items.len and std.meta.eql(before.items[original], quad)) {
            original += 1;
        } else {
            try std.testing.expect(added == null);
            added = quad;
        }
    }

    try std.testing.expectEqual(before.items.len, original);
    const progress = added orelse return error.MissingProgress;
    try std.testing.expectEqual(@as(f32, 2), progress.height);
    try std.testing.expectEqual(selected.width / 2, progress.width);
    try std.testing.expectEqual(selected.x, progress.x);
    try std.testing.expectEqual(selected.y + selected.height - progress.height, progress.y);
    _ = pane.setProgress(.{ .pane_id = Session.pane_id, .state = .remove });
    try fixture.paint(fixture.projection());
    var restored = try quadsIn(renderer.quads.items(), top);
    defer restored.deinit(std.testing.allocator);
    try std.testing.expectEqualDeep(before.items, restored.items);
}

fn quadsIn(quads: []const Quad, area: Rect) !std.ArrayList(Quad) {
    var result: std.ArrayList(Quad) = .empty;
    errdefer result.deinit(std.testing.allocator);
    for (quads) |quad| {
        if (quad.y >= area.y and quad.y + quad.height <= area.y + area.height) {
            try result.append(std.testing.allocator, quad);
        }
    }

    return result;
}

fn expectCenteredLabel(fixture: *Fixture, bounds: Rect, label: Label) !void {
    const renderer = &fixture.session.renderer;
    const actual = try firstInk(renderer.quads.items(), bounds);
    var reference = @import("../render/QuadList.zig").init(std.testing.allocator);
    defer reference.deinit();
    var canvas: Canvas = .{ .atlas = &renderer.atlas.?, .quads = &reference, .metrics = renderer.metrics, .origin = renderer.origin, .theme = fixture.session.gui.theme, .chrome = renderer.chrome, .viewport = renderer.viewport };
    const width = try canvas.measure(label);
    const natural: Rect = .{ .x = 0, .y = bounds.y, .width = width, .height = bounds.height };
    _ = try canvas.textAt(natural, label);
    const glyph = try firstInk(reference.items(), natural);
    const inset = renderer.chrome.px(8);
    const available = @max(0, bounds.width - 2 * inset);
    const left = bounds.x + inset + @floor(@max(0, available - width) / 2);
    try std.testing.expectApproxEqAbs(left + glyph.x, actual.x, 0.01);
    for (renderer.quads.items()) |quad| {
        if (!solid(quad) and quad.x >= bounds.x and quad.y >= bounds.y and quad.x + quad.width <= bounds.x + bounds.width and quad.y + quad.height <= bounds.y + bounds.height) {
            try std.testing.expect(quad.x >= bounds.x + inset);
            try std.testing.expect(quad.x + quad.width <= bounds.x + bounds.width - inset);
        }
    }
}

fn firstInk(quads: []const Quad, bounds: Rect) !Quad {
    for (quads) |quad| {
        if (!solid(quad) and quad.x >= bounds.x and quad.y >= bounds.y and quad.x + quad.width <= bounds.x + bounds.width and quad.y + quad.height <= bounds.y + bounds.height) {
            return quad;
        }
    }

    return error.MissingLabelInk;
}

fn solid(quad: Quad) bool {
    const uv = @import("../render/Quad.zig").solid_uv;
    return quad.u0 == uv[0] and quad.v0 == uv[1] and quad.u1 == uv[2] and quad.v1 == uv[3];
}
