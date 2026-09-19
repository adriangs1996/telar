const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Fixture = @import("ChromeFixture.zig");
const Session = @import("Session.zig");
const Regions = @import("../widgets/Regions.zig");
const HitMap = @import("../widgets/HitMap.zig");
const bar_regions = @import("../widgets/bar_regions.zig");
const Rect = @import("../render/Rect.zig");

test "native pane frames use the smaller pixel gutter on both axes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const model = fixture.session.gui.app.model.activeTabModel().?;
    const second: core.PaneId = @enumFromInt(20);
    const third: core.PaneId = @enumFromInt(21);
    const area = fixture.projection().geometry.area;
    try model.split(.{ .existing_pane = Session.pane_id, .new_pane = second, .location = Session.location, .axis = .horizontal, .area = area });
    try model.split(.{ .existing_pane = second, .new_pane = third, .location = Session.location, .axis = .vertical, .area = area });
    const renderer = &fixture.session.renderer;
    for ([_][2]u16{ .{ 9, 19 }, .{ 19, 9 }, .{ 12, 12 } }) |cell| {
        renderer.metrics.cell_width = cell[0];
        renderer.metrics.cell_height = cell[1];
        try fixture.resize(120, 40);
        for ([_]bool{ true, false }) |gaps| {
            _ = model.layout.setPaneGaps(gaps);
            const projection = fixture.projection();
            try fixture.paint(projection);
            var layout: client.LayoutSnapshot = .{};
            model.layout.snapshot(projection.geometry.area, &layout);
            var frames: [3]Rect = undefined;
            for (layout.views(), &frames) |view, *frame| {
                const original = renderer.metrics.rect(renderer.origin, view.outer);
                var found = false;
                for (renderer.quads.items()) |quad| {
                    if (quad.border == 1 and quad.x == original.x and quad.y == original.y) {
                        frame.* = .{ .x = quad.x, .y = quad.y, .width = quad.width, .height = quad.height };
                        found = true;
                        break;
                    }
                }

                try std.testing.expect(found);
                const content = renderer.metrics.rect(renderer.origin, view.content);
                try std.testing.expect(frame.x <= content.x and frame.y <= content.y);
                try std.testing.expect(frame.x + frame.width >= content.x + content.width);
                try std.testing.expect(frame.y + frame.height >= content.y + content.height);
                if (frame.width > original.width or frame.height > original.height) {
                    const point = if (frame.width > original.width)
                        Rect{ .x = original.x + original.width, .y = original.y, .width = 1, .height = 1 }
                    else
                        Rect{ .x = original.x, .y = original.y + original.height, .width = 1, .height = 1 };
                    try std.testing.expectEqualDeep(client.Intent{ .focus_pane = view.pane_id }, fixture.clickBand(point, 0).intent);
                }
            }

            const expected: f32 = if (gaps) @floatFromInt(@min(cell[0], cell[1])) else 0;
            try std.testing.expectEqual(expected, frames[1].x - frames[0].x - frames[0].width);
            try std.testing.expectEqual(expected, frames[2].y - frames[1].y - frames[1].height);
            const workbench = renderer.metrics.rect(renderer.origin, projection.geometry.area);
            try std.testing.expectEqual(workbench.x + workbench.width, frames[2].x + frames[2].width);
            try std.testing.expectEqual(workbench.y + workbench.height, frames[2].y + frames[2].height);
        }
    }
}

test "native chrome geometry gives the workbench every grid cell of every host" {
    for ([_]u16{ 1, 2, 3, 10, 40 }) |height| {
        for ([_]u16{ 1, 20, 61, 62, 120 }) |width| {
            const regions = Regions.calculate(width, height);
            try std.testing.expectEqual(height, regions.workbench.h);
            try std.testing.expectEqual(width, regions.workbench.w);
            try std.testing.expectEqual(regions.full, regions.workbench);
        }
    }
}

test "native chrome maps tabs workspaces and sidebar controls to stable identities" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var workspaces: client.WorkspaceListSnapshot = .{};
    _ = try workspaces.replace(.{ .revision = 1, .entries = &.{
        .{ .workspace = @enumFromInt(1), .name = "telar", .path = "/telar", .tab_count = 1 },
        .{ .workspace = @enumFromInt(9), .name = "server", .path = "/server", .tab_count = 1 },
    } });
    var projection = fixture.projection();
    projection.workspaces = &workspaces;
    try fixture.paint(projection);
    const tab = fixture.bandTarget(.{ .select_tab = Session.location.tab_id }).?;
    try std.testing.expectEqualDeep(client.Intent{ .select_tab = Session.location.tab_id }, fixture.clickBand(tab, 0).intent);
    try std.testing.expectEqualDeep(client.Intent{ .rename_tab = Session.location.tab_id }, fixture.clickBand(tab, 2).intent);
    const workspace = fixture.bandTarget(.{ .select_workspace = @enumFromInt(9) }).?;
    try std.testing.expectEqualDeep(client.Intent{ .select_workspace = @enumFromInt(9) }, fixture.clickBand(workspace, 0).intent);
    try std.testing.expect(fixture.bandTarget(.toggle_sidebar) != null);
    try std.testing.expect(fixture.bandTarget(.create_tab) != null);
    try std.testing.expectEqualDeep(client.Intent.create_tab, fixture.clickBand(fixture.bandTarget(.create_tab).?, 0).intent);
    try std.testing.expectEqual(@as(u64, 1), workspaces.revision);
}

test "native chrome preserves the resize gesture over cells and clamps scrolling" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const projection = fixture.projection();
    try fixture.paint(projection);
    const handle = fixture.resizeHandle().?;
    const band = fixture.band();
    try std.testing.expectEqual(band.width - 1 - 3, handle.x);
    try std.testing.expectEqual(@as(f32, 6), handle.width);
    const press = fixture.chrome.bandPointer(.{ .kind = .press, .x = band.width - 1, .y = band.y + 4 }).?;
    try std.testing.expect(press.interaction.consumed and press.sidebar_width == null);
    try std.testing.expect(fixture.chrome.sidebar_resize_active);
    try fixture.prepare(projection);
    // The drag crosses into the cells: the band still owns it and asks for the width under the pointer.
    const drag = fixture.chrome.bandPointer(.{ .kind = .drag, .x = 900, .y = band.y + 10 }).?;
    try std.testing.expectEqual(@as(?u32, 901), drag.sidebar_width);
    fixture.chrome.present(true);
    const release = fixture.chrome.bandPointer(.{ .kind = .release, .x = 880.4, .y = band.y + 10 }).?;
    try std.testing.expectEqual(@as(?u32, 881), release.sidebar_width);
    try std.testing.expect(fixture.chrome.band_gesture == null and !fixture.chrome.sidebar_resize_active);
    try std.testing.expect(fixture.chrome.bandPointer(.{ .kind = .press, .x = 900, .y = band.y + 10 }) == null);
    _ = fixture.chrome.bandPointer(.{ .kind = .scroll_down, .x = 2, .y = band.y + 4 });
    try std.testing.expectEqual(@as(u16, 0), fixture.chrome.sidebar.agents.scroll);
}

test "native agent targets retain generation through scroll and snapshot replacement" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    // A short band forces the cards to scroll below their header.
    try fixture.resize(120, 9);
    var agents: client.AgentSnapshot = .{};
    const entries = [_]client.AgentInput{
        .{ .key = .{ .pane_id = @enumFromInt(51), .pane_generation = 4 }, .location = Session.location, .pane_index = 1, .provider = .codex, .status = .working, .display_name = "Codex", .session_title = "Implement GUI", .workspace_label = "telar", .cwd_label = "/telar" },
        .{ .key = .{ .pane_id = @enumFromInt(52), .pane_generation = 8 }, .location = Session.location, .pane_index = 2, .provider = .claude, .status = .blocked, .display_name = "Claude" },
        .{ .key = .{ .pane_id = @enumFromInt(53), .pane_generation = 9 }, .location = Session.location, .pane_index = 3, .provider = .codex, .status = .done, .display_name = "Codex" },
    };
    _ = try agents.replace(.{ .revision = 1, .agents = &entries });
    var projection = fixture.projection();
    projection.agents = &agents;
    try fixture.paint(projection);
    const first = fixture.bandTarget(.{ .focus_agent = entries[0].key }).?;
    try std.testing.expectEqualDeep(client.Intent{ .focus_agent = entries[0].key }, fixture.clickBand(first, 0).intent);
    const list = fixture.chrome.presented().sidebar_regions.agents;
    _ = fixture.chrome.bandPointer(.{ .kind = .scroll_down, .x = list.x + 4, .y = list.y + 4 });
    try std.testing.expect(fixture.chrome.sidebar.agents.step != 0);
    try std.testing.expectEqual(@min(fixture.chrome.sidebar.agents.step, fixture.chrome.sidebar.agents.maximum_scroll), fixture.chrome.sidebar.agents.scroll);
    try fixture.paint(projection);
    try std.testing.expect(fixture.bandTarget(.{ .focus_agent = entries[2].key }) != null);
    try std.testing.expectEqual(@as(u64, 1), agents.revision);
    _ = try agents.replace(.{ .revision = 2, .agents = &.{} });
    try fixture.paint(projection);
    try std.testing.expect(fixture.bandTarget(.{ .focus_agent = entries[0].key }) == null);
    try std.testing.expectEqual(@as(u16, 0), fixture.chrome.sidebar.agents.scroll);
}

test "native tabs always retain the active tab when their row overflows" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const tabs = &fixture.session.gui.app.model.workspace;
    const second_id: core.TabId = @enumFromInt(2);
    _ = try tabs.addCreated(.{ .location = .{ .workspace = Session.location.workspace, .tab_id = second_id }, .position = 1, .label = "long second tab name", .root_pane_id = @enumFromInt(20) }, fixture.session.gui.app.model.hostSize());
    _ = tabs.select(second_id);
    try fixture.showSidebar(false);
    try fixture.resize(12, 4);
    try fixture.paint(fixture.projection());
    try std.testing.expect(fixture.bandTarget(.{ .select_tab = second_id }) != null);
    try std.testing.expect(fixture.bandTarget(.{ .select_tab = Session.location.tab_id }) == null);
}

test "native fullscreen labels keep hidden panes reachable without covering terminal content" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const model = fixture.session.gui.app.model.activeTabModel().?;
    const second: core.PaneId = @enumFromInt(20);
    try model.split(.{ .existing_pane = Session.pane_id, .new_pane = second, .location = Session.location, .axis = .horizontal, .area = fixture.projection().geometry.area });
    _ = model.layout.toggleFullscreen();
    const projection = fixture.projection();
    try fixture.paint(projection);
    const target = fixture.target(.{ .focus_pane = Session.pane_id }).?;
    try std.testing.expectEqualDeep(client.Intent{ .focus_pane = Session.pane_id }, fixture.click(target, 0).intent);
    try std.testing.expect(fixture.target(.{ .focus_pane = second }) != null);
    var layout: client.LayoutSnapshot = .{};
    model.layout.snapshot(projection.geometry.area, &layout);
    const content = fixture.session.renderer.metrics.rect(fixture.session.renderer.origin, layout.views()[0].content);
    for (fixture.session.renderer.quads.items()) |quad| {
        if (quad.a == 0 and quad.border > 0) {
            // A frame ring paints only its stroke: the content must sit inside it.
            try std.testing.expect(quad.x + quad.border <= content.x and quad.y + quad.border <= content.y);
            try std.testing.expect(quad.x + quad.width - quad.border >= content.x + content.width);
            try std.testing.expect(quad.y + quad.height - quad.border >= content.y + content.height);
            continue;
        }

        const overlaps = quad.x < content.x + content.width and quad.x + quad.width > content.x and quad.y < content.y + content.height and quad.y + quad.height > content.y;
        try std.testing.expect(!overlaps);
    }
}

test "native chrome warm repaint reuses glyphs and performs no allocation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const projection = fixture.projection();
    try fixture.paint(projection);
    const atlas = &fixture.session.renderer.atlas.?;
    const version = atlas.version;
    const calls = atlas.shape_calls;
    var failure = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = atlas.allocator;
    atlas.allocator = failure.allocator();
    defer atlas.allocator = allocator;
    const quad_allocator = fixture.session.renderer.quads.allocator;
    fixture.session.renderer.quads.allocator = failure.allocator();
    defer fixture.session.renderer.quads.allocator = quad_allocator;
    try fixture.paint(projection);
    try std.testing.expectEqual(version, atlas.version);
    try std.testing.expectEqual(calls, atlas.shape_calls);
    try std.testing.expectEqual(@as(usize, 0), failure.allocations);
}

test "native hit capacity fails explicitly and bar slots never overlap" {
    var hits: HitMap = .{};
    for (0..HitMap.capacity) |index| {
        try hits.add(.{ .area = .{ .x = @intCast(index), .w = 1, .h = 1 }, .action = .{ .intent = .toggle_sidebar } });
    }

    try std.testing.expectError(error.ChromeHitCapacityExceeded, hits.add(.{ .area = .{ .w = 1, .h = 1 }, .action = .resize_sidebar }));
    for (0..3) |tab_index| {
        for (0..80) |width| {
            const areas = bar_regions.calculate(.{ .x = 4, .y = 3, .w = @intCast(width), .h = 1 }, .{ 40, 30, 50 }, tab_index);
            try std.testing.expect(areas[0].intersect(areas[1]).isEmpty());
            try std.testing.expect(areas[1].intersect(areas[2]).isEmpty());
            try std.testing.expect(areas[0].w + areas[1].w + areas[2].w <= width);
        }
    }
}

test "native pane presses focus before forwarding and chrome cancellation releases capture" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const projection = fixture.projection();
    try fixture.paint(projection);
    const point = projection.geometry.area;
    const press = fixture.chrome.pointer(.{ .x = point.x + 2, .y = point.y + 2, .kind = .press });
    try std.testing.expectEqualDeep(client.Intent{ .focus_pane = Session.pane_id }, press.intent);
    try std.testing.expect(!press.consumed);
    try std.testing.expect(fixture.chrome.gesture_button == null);
    const wheel = fixture.chrome.pointer(.{ .x = point.x + 2, .y = point.y + 2, .kind = .scroll_down });
    try std.testing.expect(!wheel.consumed);
    try std.testing.expect(wheel.intent == .none);
    const logo = fixture.bandTarget(.toggle_sidebar).?;
    _ = fixture.chrome.bandPointer(.{ .kind = .press, .x = logo.x, .y = logo.y });
    try std.testing.expect(fixture.chrome.band_gesture != null);
    fixture.chrome.cancelPointer();
    try std.testing.expect(fixture.chrome.band_gesture == null);
    try std.testing.expect(fixture.chrome.hovered == null);
}

test "native workspace visibility follows available width and tiny bars stay within viewport" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var workspaces: client.WorkspaceListSnapshot = .{};
    _ = try workspaces.replace(.{ .revision = 1, .entries = &.{
        .{ .workspace = @enumFromInt(1), .name = "long workspace one", .path = "/one", .tab_count = 1 },
        .{ .workspace = @enumFromInt(2), .name = "long workspace two", .path = "/two", .tab_count = 1 },
    } });
    for ([_]u16{ 1, 2, 3, 6, 16, 120 }) |width| {
        try fixture.resize(width, 3);
        var projection = fixture.projection();
        projection.workspaces = &workspaces;
        projection.workspace_list_collapsed = true;
        try fixture.paint(projection);
        try std.testing.expect(fixture.bandTarget(.toggle_workspace_list) == null);
        if (width > 16) {
            try std.testing.expect(fixture.bandTarget(.{ .select_workspace = @enumFromInt(1) }) != null);
            try std.testing.expect(fixture.bandTarget(.{ .select_workspace = @enumFromInt(2) }) != null);
        }

        const renderer = &fixture.session.renderer;
        const bounds: @import("../render/Rect.zig") = .{ .x = 0, .y = 0, .width = @floatFromInt(renderer.viewport[0]), .height = @floatFromInt(renderer.viewport[1]) };
        for (renderer.quads.items()) |quad| {
            try std.testing.expect(quad.x >= bounds.x and quad.y >= bounds.y);
            try std.testing.expect(quad.x + quad.width <= bounds.x + bounds.width);
            try std.testing.expect(quad.y + quad.height <= bounds.y + bounds.height);
        }
    }
}

test "native configured bar segments preserve colors decorations and faint ink" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var state: client.State = .{};
    var content: client.Content = .{};
    try content.append(.{ .text = "Styled", .style = .{
        .foreground = .{ .value = .{ .rgb = .{ 255, 0, 0 } } },
        .background = .{ .value = .{ .rgb = .{ 0, 255, 0 } } },
        .bold = true,
        .italic = true,
        .faint = true,
        .underline = true,
        .strikethrough = true,
    } });
    state.layout.bottom = .{ .{ .content = content }, .empty, .empty };
    var projection = fixture.projection();
    projection.bar_state = &state;
    try fixture.paint(projection);
    var background = false;
    var faint_ink = false;
    var underline = false;
    const renderer = &fixture.session.renderer;
    const band = fixture.chrome.presented().bands.status_bar;
    const cell_height: f32 = @floatFromInt(renderer.metrics.cell_height);
    const row_top = band.y + @floor((band.height - cell_height) / 2);
    for (renderer.quads.items()) |quad| {
        background = background or (quad.r == 0 and quad.g == 1 and quad.b == 0 and quad.a == 1);
        faint_ink = faint_ink or (quad.r == 1 and quad.g == 0 and quad.b == 0 and quad.a == 0.5);
        underline = underline or (quad.r == 1 and quad.g == 0 and quad.b == 0 and quad.y == row_top + cell_height - 2 and quad.height == 1);
    }

    try std.testing.expect(background and faint_ink and underline);
}

test "native sidebar ignores configured footer slots" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var state: client.State = .{};
    var projection = fixture.projection();
    projection.bar_state = &state;
    try fixture.paint(projection);
    const renderer = &fixture.session.renderer;
    const before = try std.testing.allocator.dupe(@import("../render/Quad.zig").Quad, renderer.quads.items());
    defer std.testing.allocator.free(before);

    var content: client.Content = .{};
    try content.append(.{ .text = "footer", .style = .{ .background = .{ .value = .{ .rgb = .{ 0, 0, 255 } } } } });
    state.layout.sidebar_footer = .{ .{ .content = content }, .empty, .metrics };
    try fixture.paint(projection);
    try std.testing.expectEqualSlices(@import("../render/Quad.zig").Quad, before, renderer.quads.items());
}

test "native child progress remains visible with a single borderless pane" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const pane = fixture.session.gui.app.model.workspace.findPane(Session.pane_id).?;
    _ = pane.setProgress(.{ .pane_id = Session.pane_id, .state = .set, .percent = 50 });
    try fixture.paint(fixture.projection());
    const pixels = fixture.bandTarget(.{ .select_tab = Session.location.tab_id }).?;
    const renderer = &fixture.session.renderer;
    var found = false;
    for (renderer.quads.items()) |quad| {
        if (quad.radius > 0 and quad.border > 0 and quad.width == quad.height and quad.x >= pixels.x and quad.x + quad.width <= pixels.x + pixels.width and quad.y >= pixels.y and quad.y + quad.height <= pixels.y + pixels.height) {
            found = true;
        }
    }

    try std.testing.expect(found);
}

test "native mode hints preserve navigation in the top bar" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var projection = fixture.projection();
    projection.status_mode = .copy;
    try fixture.paint(projection);
    try std.testing.expect(fixture.bandTarget(.{ .select_tab = Session.location.tab_id }) != null);
    var hints: client.Hints = .{};
    hints.append(.{ .key = try client.parseKey("Ctrl+v"), .label = "split vertically" });
    projection.status_mode = .{ .prefix = hints };
    try fixture.paint(projection);
    try std.testing.expect(fixture.bandTarget(.{ .select_tab = Session.location.tab_id }) != null);
    projection.status_mode = .normal;
    try fixture.paint(projection);
    try std.testing.expect(fixture.bandTarget(.{ .select_tab = Session.location.tab_id }) != null);
}

test "native tab hit maps change only after their reordered frame is delivered" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const tabs = &fixture.session.gui.app.model.workspace;
    const second_id: core.TabId = @enumFromInt(2);
    _ = try tabs.addCreated(.{ .location = .{ .workspace = Session.location.workspace, .tab_id = second_id }, .position = 1, .label = "second", .root_pane_id = @enumFromInt(20) }, fixture.session.gui.app.model.hostSize());
    _ = tabs.select(Session.location.tab_id);
    try fixture.prepare(fixture.projection());
    try std.testing.expectEqual(@as(usize, 0), fixture.chrome.presented().hits.len);
    fixture.chrome.present(true);
    const first = fixture.bandTarget(.{ .select_tab = Session.location.tab_id }).?;
    const geometry = client.Geometry.capture(fixture.projection());
    _ = try tabs.applyPosition(second_id, 0);
    const current_geometry = client.Geometry.capture(fixture.projection());
    try std.testing.expect(geometry.matches(&current_geometry));

    try fixture.prepare(fixture.projection());
    const pending = fixture.chrome.prepared();
    const visible = fixture.chrome.presented();
    try std.testing.expect(pending != visible);
    try std.testing.expectEqualDeep(client.Intent{ .select_tab = Session.location.tab_id }, fixture.clickBand(first, 0).intent);
    fixture.chrome.present(false);
    try std.testing.expectEqual(visible, fixture.chrome.presented());
    fixture.chrome.present(true);
    try std.testing.expectEqualDeep(client.Intent{ .select_tab = Session.location.tab_id }, fixture.clickBand(first, 0).intent);

    try fixture.prepare(fixture.projection());
    fixture.chrome.present(true);
    try std.testing.expectEqual(pending, fixture.chrome.presented());
    try std.testing.expectEqualDeep(client.Intent{ .select_tab = second_id }, fixture.clickBand(first, 0).intent);
    fixture.chrome.present(true);
    try std.testing.expectEqual(pending, fixture.chrome.presented());
}

test "native GUI discards failed and stale completions before publishing controls" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const gui = session.gui;
    const initial = gui.chrome.presented();
    gui.app.model.name_prompt.begin(.create_workspace);
    const first = try gui.prepare(&session.renderer);
    try gui.complete(first + 1, true);
    try std.testing.expectEqual(initial, gui.chrome.presented());
    try std.testing.expect(gui.overlays.presented().modal == null);
    try std.testing.expect(gui.lifecycle.active != null);
    try gui.complete(first, false);
    try std.testing.expectEqual(initial, gui.chrome.presented());
    try std.testing.expect(gui.overlays.presented().modal == null);
    try std.testing.expect(gui.lifecycle.active == null);

    const next = try gui.prepare(&session.renderer);
    const prepared = gui.chrome.prepared();
    try gui.complete(first, true);
    try std.testing.expectEqual(initial, gui.chrome.presented());
    try std.testing.expect(gui.overlays.presented().modal == null);
    try gui.complete(next, true);
    try std.testing.expectEqual(prepared, gui.chrome.presented());
    try std.testing.expect(gui.overlays.presented().modal != null);
    try session.settle();
    try gui.complete(next, true);
    try std.testing.expectEqual(prepared, gui.chrome.presented());
}
