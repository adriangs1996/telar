const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Fixture = @import("ChromeFixture.zig");
const Session = @import("Session.zig");
const Regions = @import("../chrome/Regions.zig");
const Scene = @import("../render/Scene.zig");
const Overlays = @import("../overlays/Overlays.zig");
const Canvas = @import("../chrome/Canvas.zig");

test "native composed multiplexer scenes keep warm allocation shaping and cell work at zero" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.resize(160, 60);
    try populateMultiplexer(&fixture);
    const renderer = &fixture.session.renderer;
    const model = &fixture.session.gui.app.model;
    var overlays: Overlays = .{};
    var scene: Scene = .{ .terminal = renderer, .chrome = &fixture.chrome, .overlays = &overlays, .theme = fixture.session.gui.theme };
    for (0..2) |mode| {
        if (mode == 1) {
            model.name_prompt.begin(.goto_picker);
        }

        var projection = fixture.projection();
        projection.sidebar_visible = true;
        projection.geometry.area = Regions.calculate(160, 60, .{ .visible = true, .preferred_width = client.default_width }).workbench;
        _ = try scene.prepare(projection);
        const calls = renderer.atlas.?.shape_calls;
        const raster_attempts = renderer.atlas.?.raster_attempts;
        const version = renderer.atlas.?.version;
        const frame_version = renderer.atlas_version;
        const count = renderer.quads.items().len;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        renderer.allocator = failing.allocator();
        renderer.atlas.?.allocator = failing.allocator();
        renderer.quads.allocator = failing.allocator();
        renderer.cell_quads.allocator = failing.allocator();
        renderer.retained.allocator = failing.allocator();
        defer renderer.allocator = std.testing.allocator;
        defer renderer.atlas.?.allocator = std.testing.allocator;
        defer renderer.quads.allocator = std.testing.allocator;
        defer renderer.cell_quads.allocator = std.testing.allocator;
        defer renderer.retained.allocator = std.testing.allocator;
        for (0..120) |frame| {
            renderer.config.window.background_opacity = @as(f32, @floatFromInt(frame % 3)) * 0.5;
            _ = try scene.prepare(projection);
            try std.testing.expectEqual(@as(usize, 0), renderer.repainted_cells);
            try std.testing.expectEqual(renderer.config.window.background_opacity, renderer.frame(1).background[3]);
        }

        try std.testing.expectEqual(calls, renderer.atlas.?.shape_calls);
        try std.testing.expectEqual(raster_attempts, renderer.atlas.?.raster_attempts);
        try std.testing.expectEqual(version, renderer.atlas.?.version);
        try std.testing.expectEqual(count, renderer.quads.items().len);
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
        try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
        try std.testing.expectEqual(version, renderer.last_page_version);
        try std.testing.expectEqual(frame_version, renderer.atlas_version);
        const bounds: @import("../render/Rect.zig") = .{ .x = 0, .y = 0, .width = @floatFromInt(renderer.viewport[0]), .height = @floatFromInt(renderer.viewport[1]) };
        for (renderer.quads.items()) |quad| {
            try std.testing.expect(std.math.isFinite(quad.a) and quad.a >= 0 and quad.a <= 1);
            try std.testing.expect(quad.x >= bounds.x and quad.y >= bounds.y);
            try std.testing.expect(quad.x + quad.width <= bounds.x + bounds.width);
            try std.testing.expect(quad.y + quad.height <= bounds.y + bounds.height);
            try std.testing.expect(quad.u0 >= 0 and quad.v0 >= 0 and quad.u1 <= 1 and quad.v1 <= 1);
        }
    }
}

test "native decorated combining clusters remain bounded and atlas exhaustion retains valid quads" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const renderer = &fixture.session.renderer;
    const atlas = &renderer.atlas.?;
    var canvas: Canvas = .{ .atlas = atlas, .quads = &renderer.quads, .metrics = renderer.metrics, .origin = renderer.origin, .theme = fixture.session.gui.theme, .chrome = renderer.chrome, .viewport = renderer.viewport };
    const cluster = "a" ++ "\u{301}" ** 15;
    const area: core.Rect = .{ .w = 120, .h = 1 };
    renderer.quads.clear();
    try canvas.text(area, .{ .text = cluster ** 120, .color = .default, .bold = true, .italic = true, .faint = true, .underline = true, .strikethrough = true });
    const count = renderer.quads.items().len;
    try std.testing.expect(count <= area.w * @import("../render/CellMesh.zig").capacity);
    const calls = atlas.shape_calls;
    const version = atlas.version;
    renderer.quads.clear();
    try canvas.text(area, .{ .text = cluster ** 120, .color = .default, .bold = true, .italic = true, .faint = true, .underline = true, .strikethrough = true });
    try std.testing.expectEqual(calls, atlas.shape_calls);
    try std.testing.expectEqual(version, atlas.version);
    try std.testing.expectEqual(count, renderer.quads.items().len);
    atlas.shelf_y = @import("../text/GlyphAtlas.zig").side;
    renderer.quads.clear();
    try canvas.text(area, .{ .text = "Ω", .color = .default, .bold = true, .italic = true });
    try std.testing.expectEqual(version, atlas.version);
    try std.testing.expect(renderer.quads.items().len > 0);
    for (renderer.quads.items()) |quad| {
        try std.testing.expect(quad.u0 >= 0 and quad.v0 >= 0 and quad.u1 <= 1 and quad.v1 <= 1);
    }
}

fn populateMultiplexer(fixture: *Fixture) !void {
    const model = &fixture.session.gui.app.model;
    _ = try model.reconcileWorkspaceList(.{ .revision = 1, .entries = &.{
        .{ .workspace = @enumFromInt(1), .name = "telar", .path = "/telar", .tab_count = 4 },
        .{ .workspace = @enumFromInt(2), .name = "server", .path = "/server", .tab_count = 1 },
        .{ .workspace = @enumFromInt(3), .name = "web", .path = "/web", .tab_count = 1 },
    } });
    for (2..5) |id| {
        _ = try model.workspace.addCreated(.{ .location = .{ .workspace = Session.location.workspace, .tab_id = @enumFromInt(id) }, .position = @intCast(id - 1), .label = "terminal", .root_pane_id = @enumFromInt(id + 200) }, model.hostSize());
    }

    _ = model.workspace.select(Session.location.tab_id);
    const panes = model.activeTabModel().?;
    const area = Regions.calculate(160, 60, .{ .visible = true, .preferred_width = client.default_width }).workbench;
    for (1..8) |index| {
        var layout: client.LayoutSnapshot = .{};
        panes.layout.snapshot(area, &layout);
        var largest = layout.views()[0];
        for (layout.views()[1..]) |view| {
            if (@as(u32, view.content.w) * view.content.h > @as(u32, largest.content.w) * largest.content.h) {
                largest = view;
            }
        }

        try panes.split(.{ .existing_pane = largest.pane_id, .new_pane = @enumFromInt(100 + index), .location = Session.location, .axis = if (largest.content.w > largest.content.h * 2) .horizontal else .vertical, .area = area });
    }

    var identities: [core.max_panes_per_tab]core.PaneId = undefined;
    const visible = panes.layout.orderedPanes(&identities);
    var agents: [8]client.AgentInput = undefined;
    for (&agents, visible, 0..) |*agent, id, index| {
        agent.* = .{ .key = .{ .pane_id = id, .pane_generation = 1 }, .location = Session.location, .pane_index = @intCast(index + 1), .provider = .codex, .status = .working, .display_name = "Codex", .session_title = "Implement native GUI", .workspace_label = "telar", .cwd_label = "/telar" };
        const pane = panes.find(id).?;
        for (pane.buffer.cells, 0..) |*cell, cell_index| {
            cell.bytes[0] = 'a' + @as(u8, @intCast(cell_index % 26));
            cell.style.flags.bold = index % 2 == 0;
            cell.style.flags.underline = if (cell_index % 7 == 0) .single else .none;
            if (cell_index % 5 == 0) {
                cell.style.bg = .{ .indexed = 1 };
            }
        }
    }

    _ = try model.reconcileAgentSnapshot(.{ .revision = 1, .agents = &agents });
    for ([_][]const u8{ "Build complete", "Tests complete", "Format complete", "Integration complete" }) |title| {
        _ = model.publishNotification(0, .{ .title = title, .message = "All checks passed", .target = .{ .select_tab = Session.location.tab_id } });
    }

    _ = model.advanceNotifications(client.transition_duration_ns);
    try std.testing.expectEqual(@as(u8, 4), model.notification_center.count);
}
