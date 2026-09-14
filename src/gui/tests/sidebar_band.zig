//! The sidebar as a pixel band: its width from the configuration, the grid
//! it leaves beside it, the pointer targets inside it and the drag, keyboard
//! and reload paths that move it.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Fixture = @import("ChromeFixture.zig");
const ConfigFixture = @import("ConfigurationFixture.zig");
const Session = @import("Session.zig");
const Renderer = @import("../render/TerminalRenderer.zig");
const SidebarBand = @import("../chrome/SidebarBand.zig");
const InputHandler = @import("../input/InputHandler.zig");

test {
    _ = SidebarBand;
    _ = @import("../SidebarPreference.zig");
}

const agents_input = [_]client.AgentInput{
    .{ .key = .{ .pane_id = Session.pane_id, .pane_generation = 1 }, .location = Session.location, .pane_index = 1, .provider = .claude, .status = .ready, .workspace_label = "telar", .session_title = "idle shell" },
    .{ .key = .{ .pane_id = @enumFromInt(52), .pane_generation = 1 }, .location = Session.location, .pane_index = 2, .provider = .codex, .status = .working, .workspace_label = "telar", .session_title = "fix proxy tests" },
};

test "the band takes the configured width off the grid columns at scale 1 and 2 and leaves the rows alone" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    for ([_]f32{ 1, 2 }) |scale| {
        renderer.sidebar_request = .{ .visible = false };
        const without = try renderer.measure(.{ .width = 1400, .height = 800, .scale = scale });
        try std.testing.expectEqual(@as(u32, 0), renderer.sidebar.width);
        try std.testing.expectEqual(@as(u32, 0), renderer.origin[0]);
        renderer.sidebar_request = .{ .visible = true };
        const with = try renderer.measure(.{ .width = 1400, .height = 800, .scale = scale });
        const expected_width: u32 = @intFromFloat(@round(284 * scale));
        const expected_gap: u32 = @intFromFloat(@round(8 * scale));
        try std.testing.expectEqual(expected_width, renderer.sidebar.width);
        try std.testing.expectEqual(expected_gap, renderer.sidebar.gap);
        try std.testing.expectEqual(expected_width + expected_gap, renderer.origin[0]);
        try std.testing.expectEqual(without.rows, with.rows);
        try std.testing.expectEqual(@as(u16, @intCast((1400 - expected_width - expected_gap) / renderer.metrics.cell_width)), with.cols);
        try std.testing.expect(with.cols < without.cols);
        // The PTY sees complete cells only: the band and the gap are chrome.
        try std.testing.expect(renderer.origin[0] + @as(u32, with.cols) * with.cell_width_px <= 1400);
        renderer.sidebar_request = .{ .visible = true, .logical_width = 320 };
        _ = try renderer.measure(.{ .width = 1400, .height = 800, .scale = scale });
        try std.testing.expectEqual(@as(u32, @intFromFloat(@round(320 * scale))), renderer.sidebar.width);
    }
}

test "the band clamps to its bounds and to twenty workbench columns and hides below them" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    renderer.sidebar_request = .{ .visible = true, .logical_width = 100 };
    _ = try renderer.measure(.{ .width = 1400, .height = 800, .scale = 1 });
    try std.testing.expectEqual(@as(u32, 220), renderer.sidebar.width);
    renderer.sidebar_request = .{ .visible = true, .logical_width = 480 };
    _ = try renderer.measure(.{ .width = 1400, .height = 800, .scale = 1 });
    try std.testing.expectEqual(@as(u32, 480), renderer.sidebar.width);
    const cell = renderer.metrics.cell_width;
    const workbench = 20 * cell;
    const size = try renderer.measure(.{ .width = 300 + 8 + workbench, .height = 800, .scale = 1 });
    try std.testing.expectEqual(@as(u32, 300), renderer.sidebar.width);
    try std.testing.expectEqual(@as(u16, 20), size.cols);
    const narrow = try renderer.measure(.{ .width = 220 + 8 + workbench - 1, .height = 800, .scale = 1 });
    try std.testing.expectEqual(@as(u32, 0), renderer.sidebar.width);
    try std.testing.expectEqual(@as(u32, 0), renderer.origin[0]);
    try std.testing.expect(narrow.cols >= 20);
}

test "a pointer on a card focuses its agent and a pointer in the gap hits nothing" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var agents: client.AgentSnapshot = .{};
    _ = try agents.replace(.{ .revision = 1, .agents = &agents_input });
    var projection = fixture.projection();
    projection.agents = &agents;
    try fixture.paint(projection);
    const card = fixture.bandTarget(.{ .focus_agent = agents_input[1].key }).?;
    const band = fixture.band();
    try std.testing.expect(card.x >= band.x and card.x + card.width <= band.x + band.width);
    try std.testing.expectEqualDeep(client.Intent{ .focus_agent = agents_input[1].key }, fixture.clickBand(card, 0).intent);
    const renderer = &fixture.session.renderer;
    const gap_x: f64 = @floatFromInt(renderer.sidebar.width + 2);
    try std.testing.expect(fixture.chrome.bandPointer(.{ .kind = 6, .code = 1, .x = gap_x, .y = card.y }) == null);
    try std.testing.expect(fixture.session.gui.input.pointer.geometry.resolve(.{ .kind = 6, .code = 1, .x = gap_x, .y = card.y }) == null);
    try std.testing.expect(fixture.chrome.band_gesture == null);
    const first_cell: f64 = @floatFromInt(renderer.origin[0]);
    try std.testing.expect(fixture.session.gui.input.pointer.geometry.resolve(.{ .kind = 6, .code = 1, .x = first_cell, .y = card.y }) != null);
}

test "dragging the edge sets the exact width and the grid follows on the next measurement" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const projection = fixture.projection();
    try fixture.paint(projection);
    const renderer = &fixture.session.renderer;
    const gui = fixture.session.gui;
    const before = gui.app.model.hostSize();
    const band = fixture.band();
    const handle = fixture.resizeHandle().?;
    _ = fixture.chrome.bandPointer(.{ .kind = 6, .code = 1, .x = handle.x + 2, .y = band.y + 30 });
    const drag = fixture.chrome.bandPointer(.{ .kind = 6, .code = 3, .x = 339, .y = band.y + 40 }).?;
    gui.adoptSidebarWidth(drag.sidebar_width.?);
    const release = fixture.chrome.bandPointer(.{ .kind = 6, .code = 2, .x = 339, .y = band.y + 40 }).?;
    gui.adoptSidebarWidth(release.sidebar_width.?);
    try std.testing.expectEqual(@as(f32, 340), gui.sidebar.logical);
    try fixture.measure(.{ .width = renderer.viewport[0], .height = renderer.viewport[1], .scale = 1 });
    try std.testing.expectEqual(@as(u32, 340), renderer.sidebar.width);
    try std.testing.expectEqual(@as(u32, 348), renderer.origin[0]);
    const after = gui.app.model.hostSize();
    try std.testing.expectEqual(before.rows, after.rows);
    try std.testing.expect(after.cols < before.cols);
    // A drag past the bounds stops at them.
    gui.adoptSidebarWidth(2000);
    try std.testing.expectEqual(@as(f32, 480), gui.sidebar.logical);
    gui.adoptSidebarWidth(1);
    try std.testing.expectEqual(@as(f32, 220), gui.sidebar.logical);
}

test "the keyboard resize action moves the band by sixteen logical pixels without touching the shared width" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const gui = fixture.session.gui;
    const renderer = &fixture.session.renderer;
    const shared = gui.app.model.sidebarWidth();
    var handler: InputHandler = .{ .app = &gui.app };
    const revision = gui.chrome.revision;
    try std.testing.expectEqual(client.Control.continue_routing, try handler.action(.{ .resize_sidebar = .right }));
    try std.testing.expectEqual(@as(f32, 300), gui.sidebar.logical);
    try std.testing.expect(gui.chrome.revision != revision);
    try std.testing.expectEqual(client.Control.continue_routing, try handler.action(.{ .resize_sidebar = .left }));
    try std.testing.expectEqual(client.Control.continue_routing, try handler.action(.{ .resize_sidebar = .left }));
    try std.testing.expectEqual(@as(f32, 268), gui.sidebar.logical);
    try std.testing.expectEqual(shared, gui.app.model.sidebarWidth());
    try fixture.measure(.{ .width = renderer.viewport[0], .height = renderer.viewport[1], .scale = 1 });
    try std.testing.expectEqual(@as(u32, 268), renderer.sidebar.width);
    for (0..20) |_| {
        _ = try handler.action(.{ .resize_sidebar = .right });
    }

    try std.testing.expectEqual(@as(f32, 480), gui.sidebar.logical);
}

test "hiding the sidebar returns its pixels to the grid and the toggle follows the band" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.paint(fixture.projection());
    const renderer = &fixture.session.renderer;
    const gui = fixture.session.gui;
    const shown = gui.app.model.hostSize();
    try std.testing.expect(fixture.band().width > 0);
    try std.testing.expectEqual(@as(f32, 292), fixture.chrome.presented().bands.tab_strip.x);
    try fixture.showSidebar(false);
    try fixture.paint(fixture.projection());
    const hidden = gui.app.model.hostSize();
    try std.testing.expectEqual(@as(u32, 0), renderer.sidebar.width);
    try std.testing.expectEqual(@as(f32, 0), fixture.band().width);
    try std.testing.expectEqual(@as(f32, 0), fixture.chrome.presented().bands.tab_strip.x);
    try std.testing.expect(fixture.resizeHandle() == null);
    try std.testing.expectEqual(shown.rows, hidden.rows);
    try std.testing.expectEqual(shown.cols + 292 / renderer.metrics.cell_width, hidden.cols);
    try std.testing.expect(fixture.bandTarget(.toggle_sidebar) != null);
}

test "a configuration reload applies a new sidebar width without changing the PTY rows" {
    var fixture = try ConfigFixture.init("return { api_version = 2 }", null);
    defer fixture.deinit();
    const session = fixture.session;
    const reload = &session.driver.configuration;
    const viewport: @import("../native/native.zig").Viewport = .{ .width = 1400, .height = 800, .scale = 1 };
    const before = try session.gui.measure(&session.renderer, viewport);
    try session.gui.resize(before, session.renderer.theme);
    try session.settle();
    try std.testing.expectEqual(@as(u32, 284), session.renderer.sidebar.width);
    try fixture.write("config.lua", "return { api_version = 2, gui = { sidebar = { width = 400 } } }");
    try fixture.wait();
    try std.testing.expect(try reload.apply(session.gui, &session.renderer));
    try std.testing.expectEqual(@as(f32, 400), session.gui.sidebar.logical);
    const after = try session.gui.measure(&session.renderer, viewport);
    try session.gui.resize(after, session.renderer.theme);
    try session.settle();
    try std.testing.expectEqual(@as(u32, 400), session.renderer.sidebar.width);
    try std.testing.expectEqual(before.rows, after.rows);
    try std.testing.expect(after.cols < before.cols);
    try std.testing.expectEqual(after, session.gui.app.model.hostSize());
    // An unrelated reload keeps a width the person chose after the last one.
    session.gui.adoptSidebarWidth(300);
    try fixture.write("config.lua", "return { api_version = 2, gui = { sidebar = { width = 400 }, chrome = { scale = 1.1 } } }");
    try fixture.wait();
    try std.testing.expect(try reload.apply(session.gui, &session.renderer));
    try std.testing.expectEqual(@as(f32, 300), session.gui.sidebar.logical);
}
