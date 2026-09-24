const data = @import("model");
const input_support = @import("input_support.zig");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Session = @import("Session.zig");
const Fixture = @import("ChromeFixture.zig");
const Canvas = @import("../widgets/Canvas.zig");
const Composition = @import("../widgets/Composition.zig");
const FrameWidget = @import("../widgets/frame_widget.zig");
const gfx = @import("gfx");
const Quad = gfx.Quad.Quad;
const LinkHit = @import("../input/LinkHit.zig");

test "projection composes terminal thread link chrome notifications and modal before drawing" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const session = fixture.session;
    const gui = session.gui;
    const model = &gui.app.model;
    const tab = model.tabs.active;
    const thread_id: core.PaneId = @enumFromInt(20);
    try data.pane_split.split(model, tab, .{ .existing_pane = Session.pane_id, .new_pane = thread_id, .location = Session.location, .axis = .horizontal, .area = data.workbench.region(&gui.app.model).area });
    try std.testing.expect(model.tabs.layout[tab].setSurface(thread_id, .thread));
    _ = model.tabs.layout[tab].focusPane(Session.pane_id);
    try model.panes.find(thread_id).?.setComposer("Borrowed thread draft");
    const pane = model.panes.find(Session.pane_id).?;
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "https://example.com", .style = .{} });
    pane.cursor = .{ .x = 0, .y = 0, .visible = true, .appearance = .{ .shape = .bar } };
    const hit = try linkFor(&fixture);
    _ = model.publishNotification(0, .{ .title = "Build", .message = "Finished" });
    _ = model.advanceNotifications(data.notifications.transition_duration_ns);
    model.name_prompt.begin(.{ .rename_tab = .{ .tab_id = Session.location.tab_id, .label = "Borrowed title" } });
    const projection = fixture.projection();
    var canvas = begin(&fixture, &projection);
    var composition: Composition = .{ .chrome = &gui.chrome, .overlays = &gui.overlays, .canvas = &canvas, .link = &hit };
    const widgets = try composition.render(&projection);
    const expected = [_]std.meta.Tag(FrameWidget.Widget){ .terminal_pane, .thread, .link, .top_bar, .status, .sidebar, .panes, .chrome_focus, .notification, .modal };
    try std.testing.expectEqual(expected.len, widgets.len);
    for (widgets.storage[0..widgets.len], expected) |widget, tag| {
        try std.testing.expectEqual(tag, std.meta.activeTag(widget));
    }

    try std.testing.expectEqual(@as(usize, 0), session.gui.renderer.quads.items().len);
    try std.testing.expectEqual(@as(u8, 2), composition.commit.len);
    try std.testing.expectEqual(Session.pane_id, composition.commit.panes[0].pane_id);
    try std.testing.expectEqual(thread_id, composition.commit.panes[1].pane_id);
    try std.testing.expect(widgets.storage[0].terminal_pane.paint.hide_cursor);
    try std.testing.expectEqual(&composition.context, widgets.storage[3].top_bar.context);
    try std.testing.expectEqual(&projection, composition.context.projection);
    try std.testing.expectEqual(model.panes.find(thread_id).?.composerSlice().ptr, widgets.storage[1].thread.thread.composer.ptr);
    try std.testing.expectEqualStrings("Borrowed thread draft", widgets.storage[1].thread.thread.composer);
    try std.testing.expect(widgets.storage[widgets.len - 1].modal == .name_prompt);
    try widgets.draw(&canvas);
    session.gui.renderer.seal();
    try std.testing.expect(session.gui.renderer.quads.items().len > 0);
    try std.testing.expectEqual(session.gui.renderer.atlas.?.version, session.gui.renderer.last_page_version);
    try std.testing.expect(gui.overlays.prepared().modal != null);
    try std.testing.expectEqual(@as(usize, 1), gui.widgets.editors.prepared().len);
    for (session.gui.renderer.quads.items()) |quad| {
        try std.testing.expect(quad.x >= 0 and quad.y >= 0);
        try std.testing.expect(quad.x + quad.width <= @as(f32, @floatFromInt(session.gui.renderer.viewport[0])));
        try std.testing.expect(quad.y + quad.height <= @as(f32, @floatFromInt(session.gui.renderer.viewport[1])));
    }

    _ = model.name_prompt.apply(.cancel);
    const without_modal = fixture.projection();
    canvas = begin(&fixture, &without_modal);
    const with_cursor = try composition.render(&without_modal);
    try std.testing.expect(!with_cursor.storage[0].terminal_pane.paint.hide_cursor);
    try widgetsWithoutModal(&with_cursor);
    try with_cursor.draw(&canvas);
    const cursor_count = session.gui.renderer.quads.items().len;
    const shape_calls = session.gui.renderer.atlas.?.shape_calls;
    session.gui.renderer.cursor_on = false;
    canvas = begin(&fixture, &without_modal);
    const without_cursor = try composition.render(&without_modal);
    try without_cursor.draw(&canvas);
    try std.testing.expectEqual(cursor_count - 1, session.gui.renderer.quads.items().len);
    try std.testing.expectEqual(shape_calls, session.gui.renderer.atlas.?.shape_calls);
    try std.testing.expectEqual(@as(usize, 0), session.gui.renderer.repainted_cells);
}

test "complete widget list fits the maximum pane count with every optional layer" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.resize(128, 64);
    const gui = fixture.session.gui;
    const tab = gui.app.model.tabs.active;
    for (1..core.max_panes_per_tab) |index| {
        var layout: data.LayoutSnapshot = .{};
        gui.app.model.tabs.layout[tab].snapshot(data.workbench.region(&gui.app.model).area, &layout);
        var largest = layout.views()[0];
        for (layout.views()[1..]) |view| {
            if (@as(u32, view.content.w) * view.content.h > @as(u32, largest.content.w) * largest.content.h) {
                largest = view;
            }
        }

        try data.pane_split.split(&gui.app.model, tab, .{ .existing_pane = largest.pane_id, .new_pane = @enumFromInt(index + 100), .location = Session.location, .axis = if (largest.content.w > largest.content.h * 2) .horizontal else .vertical, .area = data.workbench.region(&gui.app.model).area });
    }

    _ = gui.app.model.publishNotification(0, .{ .title = "First", .message = "Finished" });
    _ = gui.app.model.publishNotification(0, .{ .title = "Second", .message = "Ready" });
    _ = gui.app.model.advanceNotifications(data.notifications.transition_duration_ns);
    gui.app.model.name_prompt.begin(.{ .rename_tab = .{ .tab_id = Session.location.tab_id, .label = "All panes" } });
    const projection = fixture.projection();
    const hit = try linkFor(&fixture);
    var canvas = begin(&fixture, &projection);
    var composition: Composition = .{ .chrome = &gui.chrome, .overlays = &gui.overlays, .canvas = &canvas, .link = &hit };
    var widgets = try composition.render(&projection);
    try std.testing.expectEqual(core.max_panes_per_tab, composition.commit.len);
    try std.testing.expectEqual(FrameWidget.capacity, widgets.len);
    try std.testing.expectEqual(@as(usize, 0), fixture.session.gui.renderer.quads.items().len);
    for (widgets.storage[0..core.max_panes_per_tab], composition.commit.slice()) |widget, commit| {
        try std.testing.expect(widget == .terminal_pane);
        try std.testing.expectEqual(commit.pane_id, widget.terminal_pane.paint.pane.id);
    }

    try std.testing.expectError(error.WidgetCapacityExceeded, widgets.append(widgets.storage[0]));
    try std.testing.expectEqual(FrameWidget.capacity, widgets.len);
    try widgets.draw(&canvas);
    try std.testing.expect(fixture.session.gui.renderer.quads.items().len > 0);
}

test "composed frame survives local widgets and replaced projection borrows until delivery" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const gui = session.gui;
    gui.app.model.name_prompt.begin(.{ .rename_tab = .{ .tab_id = Session.location.tab_id, .label = "First title" } });
    const generation = gui.app.model.name_prompt.currentConst().?.generation;
    const token = try session.draw();
    const frame = session.gui.renderer.frame(token);
    const frozen = try std.testing.allocator.dupe(Quad, session.gui.renderer.quads.items());
    defer std.testing.allocator.free(frozen);
    const targets = gui.widgets.dispatcher.maps.prepared().*;
    const editors = gui.widgets.editors.prepared().*;
    try std.testing.expect(targets.len > 0 and editors.len > 0);
    try std.testing.expectEqual(generation, editors.items[0].id.generation);

    _ = gui.app.model.name_prompt.apply(.cancel);
    gui.app.model.name_prompt.begin(.{ .rename_tab = .{ .tab_id = Session.location.tab_id, .label = "Replacement title" } });
    try session.receiveFrame(2);
    try session.settle();
    const replacement_generation = gui.app.model.name_prompt.currentConst().?.generation;
    try std.testing.expect(replacement_generation != generation);
    try std.testing.expectEqualSlices(
        Quad,
        frozen,
        session.gui.renderer.quads.items(),
    );
    try std.testing.expect(targets.equivalent(gui.widgets.dispatcher.maps.prepared()));
    for (editors.items[0..editors.len], gui.widgets.editors.prepared().items[0..editors.len]) |expected, actual| {
        try std.testing.expect(std.meta.eql(expected, actual));
    }
    const retained = session.gui.renderer.frame(token);
    try std.testing.expectEqual(frame.quads, retained.quads);
    try std.testing.expectEqual(frame.quad_count, retained.quad_count);
    try std.testing.expectEqual(frame.atlas, retained.atlas);
    try std.testing.expectEqual(frame.atlas_version, retained.atlas_version);
    try std.testing.expectEqual(frame.sprites, retained.sprites);
    try std.testing.expectEqual(frame.sprites_version, retained.sprites_version);
    try std.testing.expectError(error.PresentationBusy, session.draw());

    try input_support.presented(
        gui,
        token,
        true,
    );
    try std.testing.expect(targets.equivalent(gui.widgets.dispatcher.maps.presented()));
    try std.testing.expectEqual(generation, gui.widgets.editors.presented().items[0].id.generation);
    const pane = gui.app.model.panes.find(Session.pane_id).?;
    try std.testing.expectEqual(@as(u64, 2), pane.pending_frame_id);
    const next = try session.draw();
    try input_support.presented(
        gui,
        next,
        true,
    );
    try std.testing.expectEqual(replacement_generation, gui.widgets.editors.presented().items[0].id.generation);
    try std.testing.expectEqual(@as(u64, 0), pane.pending_frame_id);
    try session.settle();
}

fn begin(fixture: *Fixture, projection: *const client.Projection) Canvas {
    const renderer = &fixture.session.gui.renderer;
    const gui = fixture.session.gui;
    renderer.begin();
    gui.chrome.now_ns = data.notifications.transition_duration_ns;
    gui.chrome.animation.begin(gui.chrome.now_ns);
    gui.widgets.begin(projection.prompt != null);
    gui.widgets.prompt_generation = if (projection.prompt) |prompt| prompt.generation else 0;
    return .{
        .atlas = &renderer.atlas.?,
        .quads = &renderer.quads,
        .terminal_renderer = renderer,
        .metrics = renderer.metrics,
        .origin = renderer.origin,
        .theme = gui.app.model.theme,
        .background_opacity = renderer.config.window.background_opacity,
        .chrome = renderer.chrome,
        .viewport = renderer.viewport,
        .sidebar = renderer.sidebar,
        .sprites = if (renderer.sprites) |*page| page else null,
        .animation = &gui.chrome.animation,
        .widgets = &gui.widgets,
    };
}

fn linkFor(fixture: *Fixture) !LinkHit {
    const gui = fixture.session.gui;
    const pane = gui.app.model.panes.find(Session.pane_id).?;
    const view = data.tab_layout.view(&gui.app.model, gui.app.model.tabs.active, pane.id, data.workbench.region(&gui.app.model).area).?;
    return .{
        .pane_id = pane.id,
        .generation = pane.attachment_generation,
        .location = pane.location,
        .content = view.content,
        .area = view.content.row(0),
        .match = .{
            .target = try data.LinkTarget.init("https://example.com"),
            .start = .{
                .x = 0,
                .y = 0,
            },
            .end = .{
                .x = @min(19, view.content.w),
                .y = 0,
            },
        },
    };
}

fn widgetsWithoutModal(widgets: *const FrameWidget.List) !void {
    for (widgets.storage[0..widgets.len]) |widget| {
        try std.testing.expect(widget != .modal);
    }
}
