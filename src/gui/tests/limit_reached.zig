const std = @import("std");
const core = @import("telar-core");
const native = @import("../native/native.zig");
const window_callbacks = @import("../native/window_callbacks.zig");
const TestSession = @import("Session.zig");
const input_support = @import("input_support.zig");
const limit_reached = @import("../limit_reached.zig");
const event = @import("../input/event.zig");
const Scene = @import("../render/Scene.zig");
const TerminalRenderer = @import("../render/TerminalRenderer.zig");
const AccessibilityTree = @import("../native/AccessibilityTree.zig");
const Id = @import("../widgets/interaction/Id.zig");

test "a frame that stops at a limit keeps the previous frame and the window open" {
    const session = try TestSession.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const gui = session.gui;
    const delivered = try session.draw();
    try input_support.presented(gui, delivered, true);

    const callbacks = window_callbacks.bind(gui);
    const viewport: native.Viewport = .{
        .width = gui.renderer.viewport[0],
        .height = gui.renderer.viewport[1],
        .scale = gui.renderer.scale,
    };
    var frame = std.mem.zeroes(native.Frame);

    // A presentation id that ran out stops the frame after it drew.
    const next_token = gui.app.presentation.next_token;
    gui.app.presentation.next_token = std.math.maxInt(u64);
    const larger: native.Viewport = .{
        .width = viewport.width + gui.renderer.metrics.cell_width,
        .height = viewport.height,
        .scale = viewport.scale,
    };
    try session.receiveFrame(2);
    callbacks.render(gui, larger, &frame);
    try std.testing.expectEqual(@as(u64, 0), frame.token);
    try std.testing.expect(gui.failure == null);
    try std.testing.expect(callbacks.pump(gui) >= 0);

    const reaches = &gui.app.model.limit_reaches;
    const slot = reaches.find("PresentationIdExhausted").?;
    try std.testing.expectEqual(@as(u64, 1), reaches.hits[slot]);
    try std.testing.expectEqual(@as(u8, 1), gui.app.model.notification_center.count);

    // The frame cannot show its notice, so the title names the limit.
    var title: native.WindowTitle = .{};
    _ = try gui.windowTitle(&title);
    try std.testing.expect(std.mem.endsWith(u8, title.bytes[0..title.len], "limit reached: PresentationIdExhausted"));

    // The frame that stopped is not asked for, nor measured, again until
    // what it shows or its viewport changes.
    try std.testing.expect(!gui.needs_draw);
    callbacks.render(gui, larger, &frame);
    try std.testing.expectEqual(@as(u64, 0), frame.token);
    try std.testing.expectEqual(@as(u64, 1), reaches.hits[slot]);

    // A viewport just as large measures again and counts, without a second
    // notice inside the interval.
    var taller = larger;
    taller.height += gui.renderer.metrics.cell_height;
    callbacks.render(gui, taller, &frame);
    try std.testing.expectEqual(@as(u64, 0), frame.token);
    try std.testing.expectEqual(@as(u64, 2), reaches.hits[slot]);
    try std.testing.expectEqual(@as(u8, 1), gui.app.model.notification_center.count);

    gui.app.presentation.next_token = next_token;
    try session.receiveFrame(3);
    callbacks.render(gui, viewport, &frame);
    try std.testing.expect(frame.token != 0);
    try std.testing.expect(gui.limited == null);
    try std.testing.expect(gui.failure == null);

    _ = try gui.windowTitle(&title);
    try std.testing.expect(std.mem.indexOf(u8, title.bytes[0..title.len], "limit reached") == null);
}

test "a window past the protocol's cell count draws the rows that fit and reports the cut" {
    const session = try TestSession.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const gui = session.gui;
    const delivered = try session.draw();
    try input_support.presented(gui, delivered, true);

    const callbacks = window_callbacks.bind(gui);
    const metrics = gui.renderer.metrics;
    const columns: u32 = 1000;
    const rows: u32 = @intCast(core.max_cell_count / columns + 40);
    const huge: native.Viewport = .{
        .width = metrics.cell_width * columns + gui.renderer.viewport[0],
        .height = metrics.cell_height * rows + gui.renderer.viewport[1],
        .scale = gui.renderer.scale,
    };
    var frame = std.mem.zeroes(native.Frame);
    try session.receiveFrame(2);
    callbacks.render(gui, huge, &frame);
    try std.testing.expect(frame.token != 0);
    try std.testing.expect(gui.failure == null);
    try std.testing.expect(gui.limited == null);

    const grid = &gui.renderer.retained;
    try std.testing.expect(@as(u64, grid.cols) * grid.rows <= core.max_cell_count);
    // The columns stay; the rows that fit follow, the rest stays empty.
    try std.testing.expectEqual(@as(u64, core.max_cell_count / grid.cols), grid.rows);
    try std.testing.expect(gui.renderer.cut_from.? > core.max_cell_count);
    const reaches = &gui.app.model.limit_reaches;
    const slot = reaches.find("protocol.max_cell_count").?;
    try std.testing.expectEqual(@as(u64, core.max_cell_count), reaches.value[slot]);
    try std.testing.expect(reaches.requested[slot].? > core.max_cell_count);
    callbacks.complete(gui, frame.token, 1);
    try std.testing.expect(callbacks.pump(gui) >= 0);
}

test "an update event that stops at a limit is skipped and the rest of the turn runs" {
    const session = try TestSession.init();
    defer session.deinit();
    try session.bootstrap();
    const gui = session.gui;
    const callbacks = window_callbacks.bind(gui);

    try gui.driver.inbox.post(.{ .binding_timeout = error.QueueFull });
    try gui.driver.inbox.post(.{ .focus = false });
    try std.testing.expect(callbacks.pump(gui) >= 0);

    try std.testing.expect(gui.failure == null);
    try std.testing.expect(!gui.focused);
    const reaches = &gui.app.model.limit_reaches;
    const slot = reaches.find("QueueFull").?;
    try std.testing.expectEqualStrings("window_update", reaches.reachAt(slot).route);
    try std.testing.expectEqual(@as(u8, 1), gui.app.model.notification_center.count);

    // The same limit again in a later turn counts without a second notice.
    try gui.driver.inbox.post(.{ .binding_timeout = error.QueueFull });
    try std.testing.expect(callbacks.pump(gui) >= 0);
    try std.testing.expectEqual(@as(u64, 2), reaches.hits[slot]);
    try std.testing.expectEqual(@as(u8, 1), gui.app.model.notification_center.count);
}

test "a full inbox keeps a focus change and a presentation's completion for the next pump" {
    const session = try TestSession.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const gui = session.gui;
    const callbacks = window_callbacks.bind(gui);
    const token = try session.draw();
    try std.testing.expect(token != 0);

    // Fill the inbox with work the next pump drains.
    var posted: usize = 0;
    while (gui.driver.inbox.post(.input_ready)) |_| {
        posted += 1;
    } else |err| {
        try std.testing.expectEqual(error.InboxFull, err);
    }

    try std.testing.expect(posted > 0);
    try std.testing.expect(try gui.acceptInput(.{ .focus = false }));
    gui.completePresentation(.{
        .token = token,
        .delivered = true,
    });
    try std.testing.expect(gui.failure == null);
    try std.testing.expectEqual(@as(?bool, false), gui.unposted.focus);
    try std.testing.expect(gui.unposted.presented != null);

    // Each pump posts what fits, then drains a bounded batch.
    var pumps: usize = 0;
    while ((gui.unposted.focus != null or gui.unposted.presented != null or gui.focused or gui.app.presentation.active != null) and pumps < 16) : (pumps += 1) {
        try std.testing.expect(callbacks.pump(gui) >= 0);
    }

    try std.testing.expect(gui.failure == null);
    try std.testing.expect(!gui.focused);
    try std.testing.expect(gui.app.presentation.active == null);
}

test "a clipboard write or read past the capacity is refused whole and reported" {
    const session = try TestSession.init();
    defer session.deinit();
    try session.bootstrap();
    const gui = session.gui;
    const large = try std.testing.allocator.alloc(u8, event.max_text_bytes + 1);
    defer std.testing.allocator.free(large);
    @memset(large, 'a');

    try std.testing.expectError(error.ClipboardTooLarge, gui.requestClipboardWrite(large));
    try gui.requestClipboardWrite(large[0..event.max_text_bytes]);
    const reaches = &gui.app.model.limit_reaches;
    const slot = reaches.find("gui.clipboard.max_text_bytes").?;
    try std.testing.expectEqual(@as(u64, event.max_text_bytes + 1), reaches.requested[slot].?);
    try std.testing.expectEqual(@as(u64, 1), reaches.hits[slot]);

    // A read the host refused as too large reports the same limit.
    _ = try gui.update();
    try std.testing.expect(try gui.acceptInput(.{ .clipboard = .{
        .request_id = 999,
        .target_id = 0,
        .generation = 0,
        .status = .too_large,
    } }));
    _ = try gui.update();
    try std.testing.expectEqual(@as(u64, 2), reaches.hits[slot]);
}

test "a display scale past the renderer's bound draws at the bound and reports it" {
    const session = try TestSession.init();
    defer session.deinit();
    try session.bootstrap();
    const gui = session.gui;
    const bounded = limit_reached.boundViewport(gui, .{
        .width = 800,
        .height = 600,
        .scale = 12,
    });
    try std.testing.expectEqual(TerminalRenderer.max_display_scale, bounded.scale);
    try std.testing.expect(gui.app.model.limit_reaches.find("render.display_scale_max") != null);

    const same = limit_reached.boundViewport(gui, .{
        .width = 800,
        .height = 600,
        .scale = 2,
    });
    try std.testing.expectEqual(@as(f32, 2), same.scale);
}

test "a frame whose tables filled reports each by name and still draws" {
    const session = try TestSession.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const gui = session.gui;
    const token = try session.draw();
    try std.testing.expect(token != 0);

    // The prepared frame's tables as if each had left targets out.
    @constCast(gui.widgets.dispatcher.maps.prepared()).dropped = 3;
    @constCast(&gui.chrome.prepared().band_hits).dropped = 2;
    gui.renderer.quads.dropped = 5;
    var scene: Scene = .{
        .terminal = &gui.renderer,
        .chrome = &gui.chrome,
        .overlays = &gui.overlays,
        .theme = gui.app.model.theme,
        .dropped_widgets = 1,
    };
    limit_reached.reportFrame(gui, &scene);
    const reaches = &gui.app.model.limit_reaches;
    const registry = reaches.find("gui.widgets.registry_capacity").?;
    try std.testing.expectEqual(@as(u64, 1024), reaches.value[registry]);
    try std.testing.expect(reaches.find("chrome.band_hit_map_capacity") != null);
    try std.testing.expect(reaches.find("chrome.frame_widget_capacity") != null);
    try std.testing.expect(reaches.find("render.frame_quad_budget") != null);
    try std.testing.expect(reaches.find("chrome.hit_map_capacity") == null);
    try std.testing.expect(gui.failure == null);
}

test "a limit held for many frames reports once and again only after the window leaves it" {
    const session = try TestSession.init();
    defer session.deinit();
    try session.bootstrap();
    const gui = session.gui;
    const reach: core.LimitReach = .{
        .limit = limit_reached.cell_count_limit,
        .requested = core.max_cell_count + 1,
    };
    for (0..5) |_| {
        limit_reached.reportEntering(gui, .grid_cells, reach);
    }

    const reaches = &gui.app.model.limit_reaches;
    const slot = reaches.find("protocol.max_cell_count").?;
    try std.testing.expectEqual(@as(u64, 1), reaches.hits[slot]);
    limit_reached.reportEntering(gui, .grid_cells, null);
    limit_reached.reportEntering(gui, .grid_cells, reach);
    try std.testing.expectEqual(@as(u64, 2), reaches.hits[slot]);
}

test "a full accessibility tree still publishes the focused control" {
    const session = try TestSession.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const gui = session.gui;
    const token = try session.draw();
    try input_support.presented(gui, token, true);

    const registry = @constCast(gui.widgets.dispatcher.maps.presented());
    registry.reset();
    const total = AccessibilityTree.capacity + 40;
    for (0..total) |index| {
        try registry.add(.{
            .id = .{
                .target_id = index + 1,
            },
            .bounds = .{
                .x = @floatFromInt(index),
                .y = 0,
                .width = 1,
                .height = 1,
            },
            .action = .{
                .custom = index,
            },
        });
    }

    const focused: Id = .{
        .target_id = total,
    };
    gui.widgets.dispatcher.focused = focused;
    var tree: native.AccessibilityTree = .{};
    try std.testing.expect(gui.widgetAccessibility(&tree));
    try std.testing.expectEqual(@as(u32, AccessibilityTree.capacity), tree.count);
    try std.testing.expectEqual(focused.target_id, tree.nodes.?[AccessibilityTree.capacity - 1].id);
    try std.testing.expect(gui.app.model.limit_reaches.find("gui.native.accessibility_capacity") != null);
}

test "an input refused at a limit is reported under the table that refused it" {
    const session = try TestSession.init();
    defer session.deinit();
    try session.bootstrap();
    const gui = session.gui;
    try std.testing.expect(limit_reached.absorbInput(gui, .{ .paste = "held" }, error.InputPoolFull));
    try std.testing.expect(limit_reached.absorbInput(gui, .{ .text = .{ .bytes = "a", .target_id = 3 } }, error.InputPoolFull));
    try std.testing.expect(limit_reached.absorbInput(gui, .{ .text = .{ .bytes = "a", .target_id = 3 } }, error.InputTooLarge));
    try std.testing.expect(limit_reached.absorbInput(gui, null, error.NativeInputFull));
    try std.testing.expect(!limit_reached.absorbInput(gui, null, error.DeviceLost));
    const reaches = &gui.app.model.limit_reaches;
    for ([_][]const u8{ "gui.input.large_events", "gui.input.small_events", "gui.input.event_pool_bytes", "gui.input.queue_capacity" }) |name| {
        try std.testing.expect(reaches.find(name) != null);
    }
}
