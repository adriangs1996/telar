const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Fixture = @import("ChromeFixture.zig");
const Session = @import("Session.zig");
const PixelScroll = @import("../widgets/PixelScroll.zig");

test "project rows occupy the upper sidebar and keep stable workspace identities" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try projects(&fixture, 3);
    try fixture.paint(fixture.projection());
    const visible = fixture.chrome.presented();
    const list = visible.sidebar_regions.projects;
    const agents = visible.sidebar_regions.agents;
    try std.testing.expect(list.y >= visible.bands.top_bar.height);
    try std.testing.expect(list.y + list.height < agents.y);
    var previous: f32 = list.y;
    for (0..3) |index| {
        const hit = fixture.bandTarget(.{ .select_workspace = workspaceId(index) }).?;
        try std.testing.expect(hit.y >= previous);
        try std.testing.expect(hit.y + hit.height <= list.y + list.height);
        try std.testing.expectEqualDeep(client.Intent{ .select_workspace = workspaceId(index) }, fixture.clickBand(hit, 0).intent);
        try std.testing.expectEqualDeep(client.Intent.none, fixture.clickBand(hit, 2).intent);
        previous = hit.y + hit.height;
    }

    // The section rule shares the agent title's line, above its card viewport.
    var found_rule = false;
    for (fixture.session.renderer.quads.items()) |quad| {
        if (quad.height == 1 and quad.width > 80 and quad.x > list.x + 30 and quad.x + quad.width <= list.x + list.width and quad.y > list.y + list.height and quad.y < agents.y) {
            found_rule = true;
        }
    }

    try std.testing.expect(found_rule);
}

test "project and agent scrolling are independent and clipped to their delivered viewports" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try projects(&fixture, core.max_workspace_list_entries);
    try fixture.measure(.{ .width = 1100, .height = 360, .scale = 1 });
    var agents: client.AgentSnapshot = .{};
    var entries: [8]client.AgentInput = undefined;
    for (&entries, 0..) |*entry, index| {
        entry.* = .{ .key = .{ .pane_id = @enumFromInt(index + 100), .pane_generation = 1 }, .location = Session.location, .pane_index = @intCast(index + 1), .provider = .codex, .status = .working };
    }

    _ = try agents.replace(.{ .revision = 1, .agents = &entries });
    var projection = fixture.projection();
    projection.agents = &agents;
    try fixture.paint(projection);
    const regions = fixture.chrome.presented().sidebar_regions;
    try std.testing.expect(regions.projects.height <= fixture.band().height * 0.4);
    _ = fixture.chrome.bandPointer(.{ .kind = .scroll_down, .x = regions.projects.x + 1, .y = regions.projects.y + 1 });
    try std.testing.expect(fixture.chrome.sidebar.projects.scroll > 0);
    try std.testing.expectEqual(@as(u16, 0), fixture.chrome.sidebar.agents.scroll);
    const project_offset = fixture.chrome.sidebar.projects.scroll;
    _ = fixture.chrome.bandPointer(.{ .kind = .scroll_down, .x = regions.agents.x + 1, .y = regions.agents.y + 1 });
    try std.testing.expect(fixture.chrome.sidebar.agents.scroll > 0);
    try std.testing.expectEqual(project_offset, fixture.chrome.sidebar.projects.scroll);
    try fixture.paint(projection);
    try std.testing.expectEqual(project_offset, fixture.chrome.sidebar.projects.scroll);
    try std.testing.expect(fixture.bandTarget(.{ .select_workspace = workspaceId(0) }) == null);

    _ = fixture.chrome.sidebar.projects.scrollBy(13);
    try fixture.paint(projection);
    const clipped = fixture.bandTarget(.{ .select_workspace = workspaceId(1) }).?;
    try std.testing.expectEqual(regions.projects.y, clipped.y);
    try std.testing.expect(clipped.height < @as(f32, @floatFromInt(fixture.chrome.sidebar.projects.step)));
    const hits = fixture.chrome.presented().band_hits;
    for (hits.items[0..hits.len]) |hit| {
        if (hit.action == .intent and hit.action.intent == .select_workspace) {
            try std.testing.expect(hit.area.y >= regions.projects.y);
            try std.testing.expect(hit.area.y + hit.area.height <= regions.projects.y + regions.projects.height);
        }
    }

    try std.testing.expect(fixture.chrome.sidebarScrollAt(.{ regions.agents.x, regions.agents.y - 1 }) == null);
}

test "workspace changes reveal the selected row without rewinding manual scroll on repaint" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try projects(&fixture, core.max_workspace_list_entries);
    try fixture.measure(.{ .width = 1100, .height = 500, .scale = 1 });
    const tabs = &fixture.session.gui.app.model.workspace;
    const last = workspaceId(core.max_workspace_list_entries - 1);
    try tabs.replaceWithRoot(.{ .pane_id = Session.pane_id, .location = .{ .workspace = .{ .workspace = last }, .tab_id = Session.location.tab_id }, .size = fixture.session.gui.app.model.hostSize() });
    var projection = fixture.projection();
    projection.tabs = tabs;
    try fixture.paint(projection);
    const hit = fixture.bandTarget(.{ .select_workspace = last }).?;
    const region = fixture.chrome.presented().sidebar_regions.projects;
    try std.testing.expectEqual(@as(f32, @floatFromInt(fixture.chrome.sidebar.projects.step)), hit.height);
    try std.testing.expect(hit.y + hit.height <= region.y + region.height);
    try std.testing.expect(fixture.chrome.sidebar.projects.scroll > 0);
    _ = fixture.chrome.sidebar.projects.scrollBy(-100);
    const manual = fixture.chrome.sidebar.projects.scroll;
    try fixture.paint(projection);
    try std.testing.expectEqual(manual, fixture.chrome.sidebar.projects.scroll);
    try tabs.replaceWithRoot(.{ .pane_id = Session.pane_id, .location = Session.location, .size = fixture.session.gui.app.model.hostSize() });
    try fixture.paint(fixture.projection());
    try std.testing.expectEqual(@as(u16, 0), fixture.chrome.sidebar.projects.scroll);
    try std.testing.expect(fixture.bandTarget(.{ .select_workspace = workspaceId(0) }) != null);
}

test "pending sidebar layouts cannot change which list owns a delivered pointer" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try projects(&fixture, 1);
    try fixture.paint(fixture.projection());
    const old = fixture.chrome.presented().sidebar_regions;
    const point: [2]f64 = .{ old.agents.x + 2, old.agents.y + 2 };
    try projects(&fixture, core.max_workspace_list_entries);
    try fixture.prepare(fixture.projection());
    try std.testing.expectEqual(.projects, fixture.chrome.prepared().sidebar_regions.at(point).?);
    try std.testing.expect(fixture.chrome.sidebarScrollAt(point).? == &fixture.chrome.sidebar.agents);
    fixture.chrome.present(false);
    try std.testing.expect(fixture.chrome.sidebarScrollAt(point).? == &fixture.chrome.sidebar.agents);
    try fixture.paint(fixture.projection());
    try std.testing.expect(fixture.chrome.sidebarScrollAt(point).? == &fixture.chrome.sidebar.projects);
    try fixture.showSidebar(false);
    try fixture.paint(fixture.projection());
    try std.testing.expect(fixture.chrome.sidebarScrollAt(point) == null);
}

test "projects use text contrast for selection and a card background only on hover at both display scales" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try projects(&fixture, 3);
    var agents: client.AgentSnapshot = .{};
    _ = try agents.replace(.{ .revision = 1, .agents = &.{.{ .key = .{ .pane_id = Session.pane_id, .pane_generation = 1 }, .location = Session.location, .pane_index = 1, .provider = .codex, .status = .blocked }} });
    for ([_]f32{ 1, 2 }) |scale| {
        try fixture.measure(.{ .width = 1600, .height = 1200, .scale = scale });
        var projection = fixture.projection();
        projection.agents = &agents;
        fixture.chrome.hovered = .{ .intent = .{ .select_workspace = workspaceId(if (scale == 1) 1 else 0) } };
        try fixture.paint(projection);
        const hit = fixture.bandTarget(.{ .select_workspace = workspaceId(0) }).?;
        const renderer = &fixture.session.renderer;
        const other = fixture.bandTarget(.{ .select_workspace = workspaceId(1) }).?;
        const bright = fixture.session.gui.theme.palette.text.rgb;
        const muted = [3]u8{ 115, 115, 115 };
        const hovered = if (scale == 1) other else hit;
        const hover_color = fixture.session.gui.theme.palette.surface1.rgb;
        var hover_backgrounds: usize = 0;
        var bright_text = false;
        var attention_mark = false;
        for (renderer.quads.items()) |quad| {
            const active = quad.x >= hit.x and quad.y >= hit.y and quad.x + quad.width <= hit.x + hit.width and quad.y + quad.height <= hit.y + hit.height;
            const inactive = quad.x >= other.x and quad.y >= other.y and quad.x + quad.width <= other.x + other.width and quad.y + quad.height <= other.y + other.height;
            if ((active or inactive) and quad.u0 == quad.u1 and quad.v0 == quad.v1) {
                try std.testing.expectEqual(hovered.x, quad.x);
                try std.testing.expectEqual(hovered.y, quad.y);
                try std.testing.expectEqual(hovered.width, quad.width);
                try std.testing.expectEqual(hovered.height, quad.height);
                try std.testing.expectEqual(renderer.chrome.px(6), quad.radius);
                for ([_]f32{ quad.r, quad.g, quad.b }, hover_color) |actual, channel| {
                    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(channel)) / 255, actual, 0.01);
                }

                hover_backgrounds += 1;
                continue;
            }

            if (active or inactive) {
                try std.testing.expectEqual(@as(f32, 0), quad.radius);
                try std.testing.expect(quad.u0 != quad.u1 or quad.v0 != quad.v1);
            }

            if (active and @abs(quad.r - @as(f32, @floatFromInt(bright[0])) / 255) < 0.01 and @abs(quad.g - @as(f32, @floatFromInt(bright[1])) / 255) < 0.01 and @abs(quad.b - @as(f32, @floatFromInt(bright[2])) / 255) < 0.01) {
                bright_text = true;
            }

            if (inactive) {
                for ([_]f32{ quad.r, quad.g, quad.b }, muted) |actual, channel| {
                    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(channel)) / 255, actual, 0.01);
                }
            }

            if (quad.x > hit.x + hit.width - renderer.chrome.px(40) and quad.x + quad.width < hit.x + hit.width and quad.y > hit.y and quad.y + quad.height < hit.y + hit.height and quad.texture == @import("../render/Quad.zig").atlas_texture and quad.u0 != quad.u1) {
                attention_mark = true;
            }
        }

        try std.testing.expect(bright_text and attention_mark);
        try std.testing.expectEqual(@as(usize, 1), hover_backgrounds);
        try std.testing.expectEqual(hit.height, other.height);
    }
}

test "fractional scrolling and limits remain local to each sidebar list" {
    var projects_scroll: PixelScroll = .{};
    var agents_scroll: PixelScroll = .{};
    projects_scroll.setBounds(52, 200);
    agents_scroll.setBounds(72, 300);
    try std.testing.expect(!projects_scroll.scrollBy(0.75));
    try std.testing.expect(!agents_scroll.scrollBy(0.5));
    try std.testing.expect(projects_scroll.scrollBy(0.5));
    try std.testing.expectEqual(@as(u16, 1), projects_scroll.scroll);
    try std.testing.expectEqual(@as(u16, 0), agents_scroll.scroll);
    _ = projects_scroll.scrollBy(65535);
    try std.testing.expectEqual(@as(u16, 200), projects_scroll.scroll);
    projects_scroll.setBounds(52, 0);
    try std.testing.expectEqual(@as(u16, 0), projects_scroll.scroll);
}

fn workspaceId(index: usize) core.WorkspaceId {
    return if (index == 0) Session.location.workspace.workspace else @enumFromInt(index + 100);
}

fn projects(fixture: *Fixture, count: usize) !void {
    var entries: [core.max_workspace_list_entries]client.EntryInput = undefined;
    for (entries[0..count], 0..) |*entry, index| {
        entry.* = .{ .workspace = workspaceId(index), .name = if (index == 0) "telar" else "another project with a long name", .path = if (index == 0) "/sandbox/telar" else "/work/another-project-with-a-long-path", .tab_count = 1 };
    }

    const model = &fixture.session.gui.app.model;
    _ = try model.reconcileWorkspaceList(.{ .revision = model.workspaceListSnapshot().revision + 1, .entries = entries[0..count] });
}
