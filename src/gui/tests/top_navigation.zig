const cellgrid = @import("cellgrid");
const data = @import("model");
const QuadList = gfx.QuadList;
const gfx = @import("gfx");
const Quad_module = gfx.Quad;
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Fixture = @import("ChromeFixture.zig");
const sprites = @import("sprites.zig");
const Session = @import("Session.zig");
const Quad = gfx.Quad.Quad;
const Rect = gfx.Rect;
const Canvas = @import("../widgets/Canvas.zig");
const Label = @import("../widgets/Label.zig");

test "workspace departure retains the delivered indicators and overflow window until arrival" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.showSidebar(false);
    const model = &fixture.session.gui.app.model;
    const ids = [_]core.WorkspaceId{ Session.location.workspace.workspace, @enumFromInt(9), @enumFromInt(30), @enumFromInt(40), @enumFromInt(50) };
    var entries: [ids.len]data.EntryInput = undefined;
    for (ids, &entries) |id, *entry| {
        entry.* = .{ .workspace = id, .name = "project", .path = "/project", .tab_count = 1 };
    }

    _ = try data.workspace_list_snapshot.reconcile(model, .{ .revision = 1, .entries = &entries });
    for ([_]u32{ 900, 320 }) |width| {
        try fixture.measure(.{ .width = width, .height = 700, .scale = 1 });
        _ = try data.workspace_handoff.replace(model, .{ .pane_id = Session.pane_id, .location = .{ .workspace = .{ .workspace = ids[4] }, .tab_id = Session.location.tab_id }, .size = model.host.host_size });
        try fixture.paint(fixture.projection());
        const selected = fixture.bandTarget(.{ .select_workspace = ids[4] }).?;
        const region: Rect = .{ .x = 0, .y = 0, .width = selected.x + selected.width, .height = fixture.chrome.presented().bands.top_bar.height };
        var before = try quadsIn(fixture.session.gui.renderer.quads.items(), region);
        defer before.deinit(std.testing.allocator);
        var targets: [ids.len]?Rect = undefined;
        for (ids, &targets) |id, *target| {
            target.* = fixture.bandTarget(.{ .select_workspace = id });
        }

        _ = data.workspace_handoff.depart(model);
        try std.testing.expect(model.workspace == null);
        for (0..3) |_| {
            try fixture.paint(fixture.projection());
            var during = try quadsIn(fixture.session.gui.renderer.quads.items(), region);
            defer during.deinit(std.testing.allocator);
            try std.testing.expectEqualDeep(before.items, during.items);
            for (ids, targets) |id, bounds| {
                try std.testing.expectEqualDeep(bounds, fixture.bandTarget(.{ .select_workspace = id }));
            }
        }

        _ = try data.workspace_handoff.arrive(model, .{ .pane_id = Session.pane_id, .location = Session.location, .size = model.host.host_size });
        try fixture.paint(fixture.projection());
        try std.testing.expectEqual(ids[0], fixture.chrome.presented().workspace.?);
        try std.testing.expect(fixture.bandTarget(.{ .select_workspace = ids[0] }) != null);
    }
}

test "workspace handoff retains only delivered identities still present in the list" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.showSidebar(false);
    const model = &fixture.session.gui.app.model;
    _ = try data.workspace_list_snapshot.reconcile(model, .{ .revision = 1, .entries = &.{
        .{ .workspace = Session.location.workspace.workspace, .name = "telar", .path = "/telar", .tab_count = 1 },
        .{ .workspace = @enumFromInt(9), .name = "freya", .path = "/freya", .tab_count = 1 },
    } });
    try fixture.paint(fixture.projection());
    const other = try createModel();
    defer std.testing.allocator.destroy(other);
    defer other.deinit();
    try data.workspace_handoff.replaceWithRoot(other, .{ .pane_id = Session.pane_id, .location = .{ .workspace = .{ .workspace = @enumFromInt(9) }, .tab_id = Session.location.tab_id }, .size = model.host.host_size });
    var projection = fixture.projection();
    projection.model = other;
    projection.tab = other.tabs.activeSlot();
    try fixture.prepare(projection);
    fixture.chrome.present(false);
    _ = data.workspace_handoff.depart(model);
    try fixture.paint(fixture.projection());
    try std.testing.expectEqual(Session.location.workspace.workspace, fixture.chrome.presented().workspace.?);

    _ = try data.workspace_list_snapshot.reconcile(model, .{ .revision = 2, .entries = &.{
        .{ .workspace = @enumFromInt(9), .name = "freya", .path = "/freya", .tab_count = 1 },
    } });
    try fixture.paint(fixture.projection());
    try std.testing.expect(fixture.chrome.presented().workspace == null);
    try std.testing.expect(fixture.bandTarget(.{ .select_workspace = Session.location.workspace.workspace }) == null);
}

test "the rail stacks five projects in one column and reuses landed favicons at both scales" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.showSidebar(false);
    const model = &fixture.session.gui.app.model;
    _ = try data.workspace_list_snapshot.reconcile(model, .{ .revision = 1, .entries = &.{
        .{ .workspace = Session.location.workspace.workspace, .name = "telar", .path = "/telar", .tab_count = 1 },
        .{ .workspace = @enumFromInt(9), .name = "freya", .path = "/freya", .tab_count = 1 },
        .{ .workspace = @enumFromInt(30), .name = "configs", .path = "/configs", .tab_count = 1 },
        .{ .workspace = @enumFromInt(40), .name = "docs", .path = "/docs", .tab_count = 1 },
        .{ .workspace = @enumFromInt(50), .name = "website", .path = "/website", .tab_count = 1 },
    } });
    const renderer = &fixture.session.gui.renderer;
    const favicons = &fixture.chrome.favicons;
    defer favicons.deinit(std.testing.allocator);
    for ([_]f32{ 1, 2 }) |scale| {
        try fixture.measure(.{ .width = @intFromFloat(900 * scale), .height = @intFromFloat(700 * scale), .scale = scale });
        try std.testing.expect(favicons.refresh(std.testing.allocator, &renderer.sprites.?, &model.workspace_list_snapshot) == null);
        const want = favicons.next(&renderer.sprites.?, &model.workspace_list_snapshot).?;
        favicons.started(want.workspace);
        const image = try std.testing.allocator.create(client.FaviconImage);
        image.* = .{ .sides = renderer.sprites.?.cells };
        for (0..image.sides.len) |index| {
            @memset(image.mutableSlice(index), 255);
        }

        favicons.land(std.testing.allocator, .{ .workspace = want.workspace, .image = image });
        try std.testing.expect(favicons.refresh(std.testing.allocator, &renderer.sprites.?, &model.workspace_list_snapshot) == null);
        fixture.chrome.hovered = .{ .intent = .{ .select_workspace = @enumFromInt(9) } };
        try fixture.paint(fixture.projection());
        const rail = fixture.band();
        // The rail draws the landed favicon at its `large` cell, one texel per pixel.
        const large = favicons.sprite(.{ .workspace = want.workspace }, .large).?;
        try std.testing.expectEqual(@as(usize, 1), sprites.oneTexelPerPixel(renderer.quads.items(), &renderer.sprites.?, large));
        try std.testing.expect(fixture.chrome.presented().bands.rail);
        var last: f32 = 0;
        var column: ?f32 = null;
        for (0..5) |index| {
            const id = model.workspace_list_snapshot.workspaceAt(index);
            const bounds = fixture.bandTarget(.{ .select_workspace = id }).?;
            try std.testing.expect(bounds.y >= last);
            try std.testing.expectEqual(renderer.chrome.px(36), bounds.width);
            try std.testing.expectEqual(bounds.width, bounds.height);
            try std.testing.expect(bounds.x >= rail.x and bounds.x + bounds.width <= rail.x + rail.width);
            if (column) |x| {
                try std.testing.expectEqual(x, bounds.x);
            }

            column = bounds.x;
            try std.testing.expectEqual(index == 0, hasApplicationMark(renderer.quads.items(), bounds));
            _ = try firstInk(renderer.quads.items(), bounds);
            // Only the selected project carries the accent bar on the rail's edge.
            try std.testing.expectEqual(index == 0, accentBar(renderer.quads.items(), rail, bounds, renderer.chrome.px(3)));
            try std.testing.expectEqualDeep(client.Intent{ .select_workspace = id }, fixture.clickBand(bounds, 0).intent);
            last = bounds.y + bounds.height;
        }

        // The expanded sidebar's project row draws its `medium` cell the same way.
        try fixture.showSidebar(true);
        try fixture.paint(fixture.projection());
        const medium = favicons.sprite(.{ .workspace = want.workspace }, .medium).?;
        try std.testing.expectEqual(@as(usize, 1), sprites.oneTexelPerPixel(renderer.quads.items(), &renderer.sprites.?, medium));
        try fixture.showSidebar(false);
    }
}

test "rail marks without a favicon show the workspace initial and attention does not shift their ink" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.showSidebar(false);
    var workspaces: data.WorkspaceListSnapshot = .{};
    _ = try workspaces.replace(.{ .revision = 1, .entries = &.{
        .{ .workspace = Session.location.workspace.workspace, .name = "a", .path = "/a", .tab_count = 1 },
        .{ .workspace = @enumFromInt(9), .name = "a deliberately long workspace name", .path = "/long", .tab_count = 1 },
        .{ .workspace = @enumFromInt(30), .name = "xy", .path = "/xy", .tab_count = 1 },
    } });
    var projection = fixture.projection();
    projection.workspaces = &workspaces;
    try fixture.paint(projection);
    const initials = [_][]const u8{ "A", "A", "X" };
    for (initials, 0..) |text, index| {
        const bounds = fixture.bandTarget(.{ .select_workspace = workspaces.workspaceAt(index) }).?;
        try expectInitial(&fixture, bounds, .{ .text = text, .bold = true, .face = .sans, .size = .body });
    }

    const active = fixture.bandTarget(.{ .select_workspace = Session.location.workspace.workspace }).?;
    const before_dot = try firstInk(fixture.session.gui.renderer.quads.items(), active);
    var agents: data.AgentSnapshot = .{};
    _ = try agents.replace(.{ .revision = 1, .agents = &.{.{ .key = .{ .pane_id = Session.pane_id, .pane_generation = 1 }, .location = Session.location, .pane_index = 1, .provider = .codex, .status = .blocked }} });
    projection.agents = &agents;
    try fixture.paint(projection);
    const with_dot = try firstInk(fixture.session.gui.renderer.quads.items(), active);
    try std.testing.expectApproxEqAbs(before_dot.x, with_dot.x, 0.01);
    const palette = fixture.session.gui.app.model.theme.palette;
    try std.testing.expect(colored(fixture.session.gui.renderer.quads.items(), active, palette.yellow));
}

test "rail overflow counters select the nearest hidden project and keep its attention" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.showSidebar(false);
    try fixture.measure(.{ .width = 900, .height = 260, .scale = 1 });
    var workspaces: data.WorkspaceListSnapshot = .{};
    _ = try workspaces.replace(.{ .revision = 1, .entries = &.{
        .{ .workspace = @enumFromInt(4), .name = "one", .path = "/one", .tab_count = 1 },
        .{ .workspace = @enumFromInt(8), .name = "two", .path = "/two", .tab_count = 1 },
        .{ .workspace = @enumFromInt(15), .name = "three", .path = "/three", .tab_count = 1 },
        .{ .workspace = Session.location.workspace.workspace, .name = "four", .path = "/four", .tab_count = 1 },
        .{ .workspace = @enumFromInt(23), .name = "five", .path = "/five", .tab_count = 1 },
        .{ .workspace = @enumFromInt(42), .name = "six", .path = "/six", .tab_count = 1 },
        .{ .workspace = @enumFromInt(99), .name = "seven", .path = "/seven", .tab_count = 1 },
    } });
    var agents: data.AgentSnapshot = .{};
    _ = try agents.replace(.{ .revision = 1, .agents = &.{.{ .key = .{ .pane_id = @enumFromInt(70), .pane_generation = 1 }, .location = .{ .workspace = .{ .workspace = @enumFromInt(99) }, .tab_id = @enumFromInt(70) }, .pane_index = 1, .provider = .codex, .status = .blocked }} });
    var projection = fixture.projection();
    projection.workspaces = &workspaces;
    projection.agents = &agents;
    try fixture.paint(projection);
    const renderer = &fixture.session.gui.renderer;
    const counter = renderer.chrome.px(20);
    var marks: usize = 0;
    var counters: usize = 0;
    const hits = fixture.chrome.presented().band_hits;
    for (hits.items[0..hits.len]) |hit| {
        if (hit.action != .intent or hit.action.intent != .select_workspace) {
            continue;
        }

        if (hit.area.height == counter) {
            counters += 1;
            const id = hit.action.intent.select_workspace;
            // A counter names a project that is not drawn as a mark.
            var drawn = false;
            for (hits.items[0..hits.len]) |other| {
                drawn = drawn or (other.area.height != counter and other.action == .intent and std.meta.eql(other.action.intent, hit.action.intent));
            }

            try std.testing.expect(!drawn);
            try std.testing.expectEqualDeep(client.Intent{ .select_workspace = id }, fixture.clickBand(hit.area, 0).intent);
        } else {
            marks += 1;
        }
    }

    try std.testing.expect(marks < workspaces.count and marks > 0);
    try std.testing.expect(counters > 0);
    try std.testing.expect(fixture.bandTarget(.{ .select_workspace = Session.location.workspace.workspace }) != null);
    var last: ?Rect = null;
    for (hits.items[0..hits.len]) |hit| {
        if (hit.action == .intent and hit.action.intent == .select_workspace and hit.area.height == counter) {
            last = hit.area;
        }
    }

    try std.testing.expect(colored(renderer.quads.items(), last.?, fixture.session.gui.app.model.theme.palette.yellow));
}

test "native workspace visibility ignores the inherited collapse flag in wide and narrow windows" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.showSidebar(false);
    const model = &fixture.session.gui.app.model;
    _ = try data.workspace_list_snapshot.reconcile(model, .{ .revision = 1, .entries = &.{
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
        try std.testing.expect(expected[1] != null);
        try std.testing.expect(expected[2] != null);
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

        try std.testing.expectEqual(@as(usize, 3), visible);
        try std.testing.expect(fixture.bandTarget(.toggle_workspace_list) == null);
    }
}

test "native navigation names unlisted workspaces and worktrees without selecting unrelated entries" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.showSidebar(false);
    const model = try createModel();
    defer std.testing.allocator.destroy(model);
    defer model.deinit();
    const workspaces = try std.testing.allocator.create(data.WorkspaceListSnapshot);
    defer std.testing.allocator.destroy(workspaces);
    workspaces.* = .{};
    _ = try workspaces.replace(.{ .revision = 1, .entries = &.{
        .{ .workspace = @enumFromInt(1), .name = "unrelated workspace", .path = "/other", .tab_count = 1 },
        .{ .workspace = @enumFromInt(2), .name = "another workspace", .path = "/another", .tab_count = 1 },
    } });
    const renderer = &fixture.session.gui.renderer;
    for ([_]core.WorkspaceLocation{ .{ .worktree = @enumFromInt(1) }, .{ .workspace = @enumFromInt(99) } }) |location| {
        try data.workspace_handoff.replaceWithRoot(model, .{ .pane_id = Session.pane_id, .location = .{ .workspace = location, .tab_id = Session.location.tab_id }, .size = fixture.session.gui.app.model.host.host_size });
        try data.workspace_reconciliation.reconcileTabs(model, .{ .workspace = location, .name = "current context", .tabs = &.{.{ .tab_id = Session.location.tab_id, .label = "main", .pane_count = 1 }} });
        var projection = fixture.projection();
        projection.model = model;
        projection.tab = model.tabs.activeSlot();
        try fixture.paint(projection);
        const top = fixture.chrome.presented().bands.top_bar;
        var empty_snapshot = try quadsIn(renderer.quads.items(), top);
        defer empty_snapshot.deinit(std.testing.allocator);

        projection.workspaces = workspaces;
        try fixture.paint(projection);
        var unrelated_snapshot = try quadsIn(renderer.quads.items(), top);
        defer unrelated_snapshot.deinit(std.testing.allocator);
        try std.testing.expectEqualDeep(empty_snapshot.items, unrelated_snapshot.items);
        const rail = fixture.band();
        const hits = fixture.chrome.presented().band_hits;
        for (hits.items[0..hits.len]) |hit| {
            if (hit.action == .intent and hit.action.intent == .select_workspace) {
                try std.testing.expect(!accentBar(renderer.quads.items(), rail, hit.area, renderer.chrome.px(3)));
            }
        }

        try std.testing.expect(fixture.bandTarget(.{ .select_tab = Session.location.tab_id }) != null);
    }
}

test "native project indicators keep all seven projects in stable positions across selections" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.showSidebar(false);
    const workspaces = try std.testing.allocator.create(data.WorkspaceListSnapshot);
    defer std.testing.allocator.destroy(workspaces);
    workspaces.* = .{};
    _ = try workspaces.replace(.{ .revision = 1, .entries = &.{
        .{ .workspace = @enumFromInt(4), .name = "one", .path = "/one", .tab_count = 1 },
        .{ .workspace = @enumFromInt(8), .name = "two", .path = "/two", .tab_count = 1 },
        .{ .workspace = @enumFromInt(15), .name = "three with a long name", .path = "/three", .tab_count = 1 },
        .{ .workspace = @enumFromInt(16), .name = "four", .path = "/four", .tab_count = 1 },
        .{ .workspace = @enumFromInt(23), .name = "five", .path = "/five", .tab_count = 1 },
        .{ .workspace = @enumFromInt(42), .name = "six", .path = "/six", .tab_count = 1 },
        .{ .workspace = @enumFromInt(99), .name = "seven", .path = "/seven", .tab_count = 1 },
    } });
    const model = try createModel();
    defer std.testing.allocator.destroy(model);
    defer model.deinit();
    var positions: [7]?Rect = @splat(null);
    for (1..workspaces.count - 1) |index| {
        const active_id = workspaces.workspaceAt(index);
        try data.workspace_handoff.replaceWithRoot(model, .{ .pane_id = Session.pane_id, .location = .{ .workspace = .{ .workspace = active_id }, .tab_id = Session.location.tab_id }, .size = fixture.session.gui.app.model.host.host_size });
        var projection = fixture.projection();
        projection.model = model;
        projection.tab = model.tabs.activeSlot();
        projection.workspaces = workspaces;
        try fixture.paint(projection);
        const previous = fixture.bandTarget(.{ .select_workspace = workspaces.workspaceAt(index - 1) }).?;
        const active = fixture.bandTarget(.{ .select_workspace = active_id }).?;
        const next = fixture.bandTarget(.{ .select_workspace = workspaces.workspaceAt(index + 1) }).?;
        try std.testing.expectEqual(previous.width, active.width);
        try std.testing.expectEqual(next.width, active.width);
        try std.testing.expectApproxEqAbs(active.x - previous.x, next.x - active.x, 0.01);
        try std.testing.expectEqualDeep(client.Intent{ .select_workspace = active_id }, fixture.clickBand(active, 0).intent);
        for (0..workspaces.count) |slot| {
            const bounds = fixture.bandTarget(.{ .select_workspace = workspaces.workspaceAt(slot) }).?;
            if (positions[slot]) |previous_bounds| {
                try std.testing.expectEqualDeep(previous_bounds, bounds);
            }

            positions[slot] = bounds;
        }

        var slots: usize = 0;
        const hits = fixture.chrome.presented().band_hits;
        for (hits.items[0..hits.len]) |hit| {
            if (hit.action == .intent and hit.action.intent == .select_workspace and hit.area.width == active.width) {
                slots += 1;
            }
        }

        try std.testing.expectEqual(@as(usize, 7), slots);
        projection.workspace_list_collapsed = true;
        try fixture.paint(projection);
        try std.testing.expectEqualDeep(previous, fixture.bandTarget(.{ .select_workspace = workspaces.workspaceAt(index - 1) }).?);
        try std.testing.expectEqualDeep(active, fixture.bandTarget(.{ .select_workspace = active_id }).?);
        try std.testing.expectEqualDeep(next, fixture.bandTarget(.{ .select_workspace = workspaces.workspaceAt(index + 1) }).?);
        try std.testing.expect(fixture.bandTarget(.toggle_workspace_list) == null);
    }
}

test "tabs pack from the left beside the workbench or the context name in both sidebar states" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const model = &fixture.session.gui.app.model;
    _ = try data.workspace_list_snapshot.reconcile(model, .{ .revision = 1, .entries = &.{
        .{ .workspace = Session.location.workspace.workspace, .name = "telar", .path = "/telar", .tab_count = 2 },
        .{ .workspace = @enumFromInt(9), .name = "server", .path = "/server", .tab_count = 1 },
        .{ .workspace = @enumFromInt(30), .name = "config", .path = "/config", .tab_count = 1 },
    } });
    _ = try data.tab_creation.add(model, .{ .location = .{ .workspace = Session.location.workspace, .tab_id = @enumFromInt(2) }, .position = 1, .label = "editor", .root_pane_id = @enumFromInt(20) }, model.host.host_size);

    for ([_]u32{ 900, 1600 }) |width| {
        try fixture.measure(.{ .width = width, .height = 700, .scale = 1 });
        for ([_]bool{ true, false }) |expanded| {
            try fixture.showSidebar(expanded);
            try fixture.paint(fixture.projection());
            const top = fixture.chrome.presented().bands.top_bar;
            const band = fixture.band();
            const workspace = fixture.bandTarget(.{ .select_workspace = Session.location.workspace.workspace }).?;
            const first_tab = fixture.bandTarget(.{ .select_tab = Session.location.tab_id }).?;
            const second_tab = fixture.bandTarget(.{ .select_tab = @enumFromInt(2) }).?;
            const plus = fixture.bandTarget(.create_tab).?;
            try std.testing.expectEqual(@as(f32, 42), top.height);
            try std.testing.expectEqual(@as(u32, 42), fixture.session.gui.renderer.origin[1]);
            try std.testing.expect(first_tab.x < top.x + top.width / 2);
            try std.testing.expect(first_tab.x + first_tab.width <= second_tab.x);
            try std.testing.expect(second_tab.x + second_tab.width <= plus.x);
            try std.testing.expect(plus.x - (second_tab.x + second_tab.width) <= 4);
            try std.testing.expectApproxEqAbs(top.y + top.height / 2, first_tab.y + first_tab.height / 2, 1);
            try std.testing.expectEqual(first_tab.y, second_tab.y);
            if (expanded) {
                // Tabs start where the workbench does, beside the sidebar.
                try std.testing.expect(workspace.y >= top.height);
                try std.testing.expect(first_tab.x >= band.x + band.width);
            } else {
                // Beside the rail, the context name comes first.
                try std.testing.expect(workspace.x + workspace.width <= band.x + band.width);
                try std.testing.expect(first_tab.x > top.x + fixture.session.gui.renderer.chrome.px(16));
            }
        }
    }
}

test "native active tab remains reachable after long preceding labels at narrow window widths" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const model = &fixture.session.gui.app.model;
    _ = try data.workspace_list_snapshot.reconcile(model, .{ .revision = 1, .entries = &.{
        .{ .workspace = Session.location.workspace.workspace, .name = "a workspace with a long name", .path = "/one", .tab_count = 8 },
        .{ .workspace = @enumFromInt(2), .name = "another workspace with a long name", .path = "/two", .tab_count = 1 },
        .{ .workspace = @enumFromInt(3), .name = "third workspace with a long name", .path = "/three", .tab_count = 1 },
    } });
    _ = try data.tab_rename.rename(model, Session.location.tab_id, "first tab with a deliberately long label");
    for (1..8) |index| {
        _ = try data.tab_creation.add(model, .{ .location = .{ .workspace = Session.location.workspace, .tab_id = @enumFromInt(index + 1) }, .position = @intCast(index), .label = "another tab with a deliberately long label", .root_pane_id = @enumFromInt(index + 20) }, model.host.host_size);
    }

    try fixture.showSidebar(false);
    for ([_]u32{ 120, 240, 480, 900 }) |width| {
        try fixture.measure(.{ .width = width, .height = 500, .scale = 1 });
        for ([_]core.TabId{ @enumFromInt(8), @enumFromInt(4), Session.location.tab_id }) |active| {
            _ = data.tab_selection.select(model, active);
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

test "native selected tab preserves its rounded surface and hosts an explicit child progress ring" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.paint(fixture.projection());
    const renderer = &fixture.session.gui.renderer;
    const top = fixture.chrome.presented().bands.top_bar;
    const selected = fixture.bandTarget(.{ .select_tab = Session.location.tab_id }).?;
    var rounded = false;
    for (renderer.quads.items()) |quad| {
        if (quad.radius > 0 and quad.x >= selected.x and quad.x + quad.width <= selected.x + selected.width and quad.y >= selected.y and quad.y + quad.height <= selected.y + selected.height and quad.width > quad.height) {
            rounded = true;
        }
    }

    try std.testing.expect(rounded);
    try std.testing.expect(progressRing(renderer.quads.items(), selected) == null);
    var before = try quadsIn(renderer.quads.items(), top);
    defer before.deinit(std.testing.allocator);
    const pane = fixture.session.gui.app.model.panes.find(Session.pane_id).?;
    _ = pane.setProgress(.{ .pane_id = Session.pane_id, .state = .set, .percent = 50 });
    try fixture.paint(fixture.projection());
    // The trailing status slot widens the tab rather than covering its caption.
    const widened = fixture.bandTarget(.{ .select_tab = Session.location.tab_id }).?;
    try std.testing.expect(widened.width > selected.width);
    const progress = progressRing(renderer.quads.items(), widened) orelse return error.MissingProgress;
    try std.testing.expect(progress.width > 2);
    try std.testing.expectApproxEqAbs(selected.y + selected.height / 2, progress.y + progress.height / 2, 0.001);
    try std.testing.expectEqualDeep(client.Intent{ .select_tab = Session.location.tab_id }, fixture.clickBand(selected, 0).intent);
    _ = pane.setProgress(.{ .pane_id = Session.pane_id, .state = .remove });
    fixture.chrome.hovered = null;
    try fixture.paint(fixture.projection());
    try std.testing.expect(progressRing(renderer.quads.items(), selected) == null);
    var restored = try quadsIn(renderer.quads.items(), top);
    defer restored.deinit(std.testing.allocator);
    try std.testing.expectEqualDeep(before.items, restored.items);
}

fn progressRing(quads: []const Quad, area: Rect) ?Quad {
    for (quads) |quad| {
        if (quad.radius > 0 and quad.border > 0 and quad.width == quad.height and quad.x >= area.x and quad.x + quad.width <= area.x + area.width and quad.y >= area.y and quad.y + quad.height <= area.y + area.height) {
            return quad;
        }
    }

    return null;
}

fn quadsIn(quads: []const Quad, area: Rect) !std.ArrayList(Quad) {
    var result: std.ArrayList(Quad) = .empty;
    errdefer result.deinit(std.testing.allocator);
    for (quads) |quad| {
        if (quad.x >= area.x and quad.x + quad.width <= area.x + area.width and quad.y >= area.y and quad.y + quad.height <= area.y + area.height) {
            try result.append(std.testing.allocator, quad);
        }
    }

    return result;
}

// A rail mark's initial is centred in the mark's 20 px box.
fn expectInitial(fixture: *Fixture, bounds: Rect, label: Label) !void {
    const renderer = &fixture.session.gui.renderer;
    var reference = QuadList.init(std.testing.allocator);
    defer reference.deinit();
    var canvas: Canvas = .{ .atlas = &renderer.atlas.?, .quads = &reference, .metrics = renderer.metrics, .origin = renderer.origin, .theme = fixture.session.gui.app.model.theme, .chrome = renderer.chrome, .viewport = renderer.viewport };
    const width = try canvas.measure(label);
    const side = renderer.chrome.px(20);
    const box: Rect = .{ .x = bounds.x + (bounds.width - side) / 2, .y = bounds.y + (bounds.height - side) / 2, .width = side, .height = side };
    const natural: Rect = .{ .x = box.x + (box.width - width) / 2, .y = box.y, .width = width, .height = box.height };
    const actual = try firstInk(renderer.quads.items(), natural);
    _ = try canvas.textAt(natural, label);
    const glyph = try firstInk(reference.items(), natural);
    try std.testing.expectApproxEqAbs(glyph.x, actual.x, 0.01);
    try std.testing.expectApproxEqAbs(glyph.y, actual.y, 0.01);
    try std.testing.expectEqualSlices(f32, &.{ glyph.u0, glyph.v0, glyph.u1, glyph.v1 }, &.{ actual.u0, actual.v0, actual.u1, actual.v1 });
}

fn firstInk(quads: []const Quad, bounds: Rect) !Quad {
    for (quads) |quad| {
        if (!solid(quad) and quad.x >= bounds.x and quad.y >= bounds.y and quad.x + quad.width <= bounds.x + bounds.width and quad.y + quad.height <= bounds.y + bounds.height) {
            return quad;
        }
    }

    return error.MissingLabelInk;
}

// A solid bar of `width` on the rail's left edge, level with `bounds`.
fn accentBar(quads: []const Quad, rail: Rect, bounds: Rect, width: f32) bool {
    for (quads) |quad| {
        if (quad.x == rail.x and quad.width == width and quad.y >= bounds.y and quad.y + quad.height <= bounds.y + bounds.height) {
            return true;
        }
    }

    return false;
}

fn colored(quads: []const Quad, bounds: Rect, color: cellgrid.Color) bool {
    const rgb = color.rgbChannels().?;
    for (quads) |quad| {
        const inside = quad.x >= bounds.x and quad.y >= bounds.y and quad.x + quad.width <= bounds.x + bounds.width and quad.y + quad.height <= bounds.y + bounds.height;
        const matches = @abs(quad.r - @as(f32, @floatFromInt(rgb[0])) / 255) < 0.01 and @abs(quad.g - @as(f32, @floatFromInt(rgb[1])) / 255) < 0.01 and @abs(quad.b - @as(f32, @floatFromInt(rgb[2])) / 255) < 0.01;
        if (inside and matches and quad.a > 0) {
            return true;
        }
    }

    return false;
}

fn solid(quad: Quad) bool {
    return quad.u0 == Quad_module.solid_uv[0] and quad.v0 == Quad_module.solid_uv[1] and quad.u1 == Quad_module.solid_uv[2] and quad.v1 == Quad_module.solid_uv[3];
}

test "native automatic tabs show the foreground application mark and preserve manual titles" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const model = &fixture.session.gui.app.model;
    const tab = model.tabs.find(Session.location.tab_id).?;
    model.tabs.setLabel(tab, "");
    const pane = model.panes.find(Session.pane_id).?;
    _ = pane.setForegroundName("codex");
    try fixture.paint(fixture.projection());
    try std.testing.expectEqualStrings("codex", data.tab_label.text(model, tab));
    const bounds = fixture.bandTarget(.{ .select_tab = Session.location.tab_id }).?;
    try std.testing.expect(hasApplicationMark(fixture.session.gui.renderer.quads.items(), bounds));

    // Choosing the same text explicitly still disables automatic naming; the
    // mark keeps following the application, as the chip of every tab does.
    _ = try data.tab_rename.rename(model, Session.location.tab_id, "codex");
    _ = pane.setForegroundName("nvim");
    try fixture.paint(fixture.projection());
    try std.testing.expectEqualStrings("codex", data.tab_label.text(model, tab));
    try std.testing.expectEqual(data.icons.Icon.app_editor, data.tab_label.mark(model, tab));
    try std.testing.expect(!hasApplicationMark(fixture.session.gui.renderer.quads.items(), fixture.bandTarget(
        .{
            .select_tab = Session.location.tab_id,
        },
    ).?));

    model.tabs.setLabel(tab, "");
    try fixture.paint(fixture.projection());
    try std.testing.expectEqualStrings("nvim", data.tab_label.text(model, tab));
    try std.testing.expect(data.tab_label.icon(model, tab) != null);
    try std.testing.expect(fixture.bandTarget(.{ .select_tab = Session.location.tab_id }) != null);
}

fn hasApplicationMark(quads: []const Quad, bounds: Rect) bool {
    for (quads) |quad| {
        if (quad.texture == Quad_module.sprite_texture and quad.x >= bounds.x and quad.y >= bounds.y and quad.x + quad.width <= bounds.x + bounds.width and quad.y + quad.height <= bounds.y + bounds.height) {
            return true;
        }
    }

    return false;
}

fn createModel() !*data.ClientModel {
    const model = try std.testing.allocator.create(data.ClientModel);
    model.* = data.ClientModel.init(std.testing.allocator, true);
    return model;
}
