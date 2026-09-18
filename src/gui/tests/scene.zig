const std = @import("std");
const Session = @import("Session.zig");

test "native theme backgrounds share window opacity across bands and pane headers" {
    const client = @import("telar-client");
    var fixture = try @import("ChromeFixture.zig").init();
    defer fixture.deinit();
    const renderer = &fixture.session.renderer;
    const model = &fixture.session.gui.app.model;
    const projection = fixture.projection();
    const panes = model.activeTabModel().?;
    try panes.split(.{ .existing_pane = Session.pane_id, .new_pane = @enumFromInt(20), .location = Session.location, .axis = .horizontal, .area = projection.geometry.area });
    var overlays: @import("../widgets/overlays/Overlays.zig") = .{};
    var scene: @import("../render/Scene.zig") = .{ .terminal = renderer, .chrome = &fixture.chrome, .overlays = &overlays, .theme = client.theme_support.builtin(.vesper) };

    for ([_]client.theme_support.Builtin{ .vesper, .shade, .catppuccin, .tokyo_night, .terminal }) |theme| {
        scene.theme = client.theme_support.builtin(theme);
        for ([_]f32{ 1, 0.95, 0.5, 0, 1 }) |opacity| {
            renderer.config.window.background_opacity = opacity;
            _ = try scene.prepare(fixture.projection());
            const bands = fixture.chrome.prepared().bands;
            const points = [_][2]f32{
                .{ bands.top_bar.x + bands.top_bar.width - 2, bands.top_bar.y + bands.top_bar.height / 2 },
                .{ bands.top_bar.x + bands.top_bar.width / 2, bands.top_bar.y + 1 },
                .{ bands.sidebar.x + bands.sidebar.width / 2, bands.sidebar.y + bands.sidebar.height - 40 },
                .{ bands.status_bar.x + bands.status_bar.width - 2, bands.status_bar.y + bands.status_bar.height / 2 },
            };
            for (points) |point| {
                try std.testing.expectApproxEqAbs(opacity, (try backgroundColor(renderer, point))[3], 0.0001);
            }

            var layout: client.LayoutSnapshot = .{};
            panes.layout.snapshot(projection.geometry.area, &layout);
            for (layout.views()) |view| {
                const header = renderer.metrics.rect(renderer.origin, view.outer.row(0));
                try std.testing.expectApproxEqAbs(opacity, (try backgroundColor(renderer, .{ header.x + header.width / 2, header.y + header.height / 2 }))[3], 0.0001);
            }
        }
    }

    renderer.config.window.background_opacity = 0.5;
    scene.theme = client.theme_support.builtin(.vesper);
    model.name_prompt.begin(.create_workspace);
    _ = try scene.prepare(fixture.projection());
    const modal = overlays.prepared().native_modal.?;
    try std.testing.expectEqual(@as(f32, 1), (try backgroundColor(renderer, .{ modal.x + modal.width / 2, modal.y + 10 }))[3]);
}

test "agent and terminal panes share the configured theme background opacity and blur" {
    const client = @import("telar-client");
    var fixture = try @import("ChromeFixture.zig").init();
    defer fixture.deinit();
    const renderer = &fixture.session.renderer;
    const model = &fixture.session.gui.app.model;
    const panes = model.activeTabModel().?;
    try panes.split(.{ .existing_pane = Session.pane_id, .new_pane = @enumFromInt(20), .location = Session.location, .axis = .horizontal, .area = fixture.projection().geometry.area });
    try std.testing.expect(model.identifyPane(.{ .request_id = @enumFromInt(1), .pane_id = Session.pane_id, .location = Session.location, .created = false, .kind = .agent, .pane_generation = 77 }));
    var overlays: @import("../widgets/overlays/Overlays.zig") = .{};
    var scene: @import("../render/Scene.zig") = .{ .terminal = renderer, .chrome = &fixture.chrome, .overlays = &overlays, .theme = client.theme_support.builtin(.vesper) };
    renderer.config.window.background_blur = 40;
    for ([_]client.theme_support.Builtin{ .vesper, .shade, .catppuccin, .tokyo_night, .terminal }) |theme| {
        scene.theme = client.theme_support.builtin(theme);
        if (theme == .terminal) {
            scene.theme.terminal.background = .{ 17, 43, 71 };
        }

        renderer.theme = scene.theme.terminal;
        for ([_]f32{ 0.5, 0, 0.95, 1 }) |opacity| {
            renderer.config.window.background_opacity = opacity;
            const projection = fixture.projection();
            var layout: client.LayoutSnapshot = .{};
            panes.layout.snapshot(projection.geometry.area, &layout);
            for (layout.views()) |view| {
                _ = panes.focusPane(view.pane_id);
                _ = try scene.prepare(fixture.projection());
                try std.testing.expectEqual(@as(u32, 40), renderer.frame(1).background_blur);
                const bounds = renderer.metrics.rect(renderer.origin, view.content);
                const color = try backgroundColor(renderer, .{ bounds.x + 2, bounds.y + bounds.height / 2 });
                try std.testing.expectApproxEqAbs(opacity, color[3], 0.0001);
                for (scene.theme.terminal.background, color[0..3]) |component, actual| {
                    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(component)) / 255 * opacity, actual, 0.0001);
                }
            }
        }
    }
}

// Samples premultiplied color away from glyphs, rounded corners and frame strokes.
fn backgroundColor(renderer: *const @import("../render/TerminalRenderer.zig"), point: [2]f32) ![4]f32 {
    const quad = @import("../render/Quad.zig");
    var color = renderer.frame(1).background;
    for (color[0..3]) |*component| {
        component.* *= color[3];
    }

    for (renderer.quads.items()) |item| {
        if (point[0] < item.x or point[0] >= item.x + item.width or point[1] < item.y or point[1] >= item.y + item.height) {
            continue;
        }

        if (item.border > 0 and item.a == 0 and point[0] > item.x + item.border and point[0] < item.x + item.width - item.border and point[1] > item.y + item.border and point[1] < item.y + item.height - item.border) {
            continue;
        }

        try std.testing.expectEqual(quad.solid_uv[0], item.u0);
        try std.testing.expectEqual(quad.solid_uv[1], item.v0);
        for (color[0..3], [_]f32{ item.r, item.g, item.b }) |*component, source| {
            component.* = source * item.a + component.* * (1 - item.a);
        }

        color[3] = item.a + color[3] * (1 - item.a);
    }

    return color;
}

test "native scene captures terminal and thread damage in the same presentation" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    try std.testing.expectEqual(pane.id, session.gui.cursorTarget().pane_id);
    const layout = &session.gui.app.model.activeTabModel().?.layout;
    try std.testing.expect(layout.setSurface(pane.id, .thread));
    const token = try session.gui.prepare(&session.renderer);
    const commit = session.gui.lifecycle.active.?.delivery.commit;
    try std.testing.expectEqual(@as(u8, 1), commit.len);
    try std.testing.expectEqual(pane.id, commit.panes[0].pane_id);
    try std.testing.expect(session.renderer.quads.items().len > 0);
    try std.testing.expectEqual(session.renderer.atlas.?.version, session.renderer.last_page_version);
    try session.gui.complete(token, true);
    try session.settle();
    try std.testing.expectEqual(@as(u64, 0), pane.pending_frame_id);
}

test "native copy selection recolors only projected cells and restores retained ink" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    const canonical = pane.buffer.cells[0];
    const view = session.gui.app.model.activeTabModel().?.viewForPane(pane.id, session.gui.region.area).?;
    const position = [2]u16{ view.content.x, view.content.y };
    var projection = session.gui.projection();
    _ = try session.renderer.prepare(projection);
    const original = session.renderer.retained.at(position).items()[0];
    projection.copy = .{ .pane_id = pane.id, .view = .{ .cursor = .{ .x = 0, .y = pane.scroll.offset }, .anchor = .{ .x = 0, .y = pane.scroll.offset }, .linewise = false } };
    _ = try session.renderer.prepare(projection);
    try std.testing.expectEqual(@as(usize, 1), session.renderer.repainted_cells);
    const selected = session.renderer.retained.at(position).items()[0];
    try std.testing.expect(original.r != selected.r or original.g != selected.g or original.b != selected.b);
    try std.testing.expectEqualDeep(canonical, pane.buffer.cells[0]);
    projection.copy = null;
    _ = try session.renderer.prepare(projection);
    try std.testing.expectEqualDeep(original, session.renderer.retained.at(position).items()[0]);
    try std.testing.expectEqual(@as(usize, 1), session.renderer.repainted_cells);
}

test "native prefix and chrome hover invalidate presentation without changing model state" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const token = try session.gui.prepare(&session.renderer);
    try session.gui.complete(token, true);
    try session.settle();
    const version = session.gui.app.model.version();
    try session.gui.input.accept(.{ .kind = 4, .code = 'b', .mods = 4 });
    try session.gui.input.drain(&session.gui.app);
    try std.testing.expectEqualDeep(version, session.gui.app.model.version());
    _ = session.gui.lifecycle.observe(session.gui.observation());
    try std.testing.expect(session.gui.lifecycle.needsPreparation());
    try std.testing.expect(session.gui.projection().status_mode == .prefix);
    const prefix = try session.gui.prepare(&session.renderer);
    try session.gui.complete(prefix, true);
    try session.settle();
    _ = session.gui.chrome.pointer(.{ .x = 0, .y = 0, .kind = .move });
    _ = session.gui.lifecycle.observe(session.gui.observation());
    try std.testing.expect(session.gui.lifecycle.needsPreparation());
    try std.testing.expectEqualDeep(version, session.gui.app.model.version());
}
