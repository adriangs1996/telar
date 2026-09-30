//! Client integration tests for host interaction: resizes, capability
//! replies, viewport intents, copy mode and link pointers.
const keyinput = @import("keyinput");

const core = @import("telar-core");
const data = @import("model");
const client_module = @import("telar-client");
const keys = @import("keys.zig");
const ClientHarness = @import("ClientHarness.zig");
const fixtures = @import("fixtures.zig");
const std = @import("std");

/// One measured host window: its grid and its pixels.
const Measurement = struct {
    cols: u16,
    rows: u16,
    width_px: u32,
    height_px: u32,
};

test "host resize commits before resources and presents by model version" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const measurement: Measurement = .{
        .cols = 100,
        .rows = 30,
        .width_px = 1000,
        .height_px = 600,
    };

    const commit = (try resizeHost(client, measurement)).?.resize.?;
    try harness.deliverHostEffects();

    const expected: core.TerminalSize = .{
        .cols = 100,
        .rows = 30,
        .cell_width_px = 10,
        .cell_height_px = 20,
    };
    try std.testing.expectEqualDeep(expected, commit.current);
    try std.testing.expectEqualDeep(expected, client.model.host.host_size);
    try std.testing.expectEqual(data.Version{
        .host = 1,
        .host_capabilities = 1,
        .workspace = 1,
        .tabs = 1,
        .active_tab = 1,
        .panes = 1,
    }, client.model.version());
    const active = client.model.tabs.active;
    try std.testing.expectEqual(@as(u16, 10), client.model.host.host_size.cell_width_px);
    try std.testing.expectEqual(@as(u16, 20), client.model.host.host_size.cell_height_px);

    const expected_pane_size = data.tab_layout.contentSize(
        &client.model,
        active,
        ClientHarness.bootstrap_pane,
        client.geometry().area,
    ).?;
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .pane_resize);
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, message.pane_resize.pane_id);
    try std.testing.expectEqualDeep(expected_pane_size, message.pane_resize.size);

    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.delivered.model);

    const version = client.model.version();
    try std.testing.expect((try resizeHost(client, measurement)) == null);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "host resize retains committed geometry after outbox backpressure" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    while (client.model.to_runtime.hasCapacity()) {
        try client.model.to_runtime.push(.{ .detach_pane = .{ .pane_id = ClientHarness.bootstrap_pane } });
    }

    const measurement: Measurement = .{
        .cols = 90,
        .rows = 28,
        .width_px = 900,
        .height_px = 560,
    };

    try std.testing.expectError(error.ClientOutboxFull, resizeHost(client, measurement));
    try harness.deliverHostEffects();

    try std.testing.expectEqual(core.TerminalSize{
        .cols = 90,
        .rows = 28,
        .cell_width_px = 10,
        .cell_height_px = 20,
    }, client.model.host.host_size);
    try std.testing.expectEqual(@as(u64, 1), client.model.version().host);
    try std.testing.expectEqual(@as(u64, 1), client.model.version().host_capabilities);
    try std.testing.expectEqual(@as(usize, data.outbox_support.capacity), client.model.to_runtime.len);
}

test "host resize waits for canonical membership then resizes before attaching without duplicate opens" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const tab = client.model.tabs.active;
    const sibling: core.PaneId = @enumFromInt(20);
    try data.tab_snapshot_reconciliation.addDiscovered(
        &client.model,
        tab,
        .{
            .pane_id = sibling,
            .location = client.model.tabs.location[tab],
            .area = client.geometry().area,
        },
    );
    try std.testing.expect(!client.model.tabs.snapshot_loaded[tab]);
    const initial_request_id = client.model.request_lifecycle.next_request_id;
    var buffer: [256]u8 = undefined;

    _ = try resizeHost(
        client,
        .{
            .cols = 90,
            .rows = 28,
            .width_px = 900,
            .height_px = 560,
        },
    );
    try harness.settle();
    const before_snapshot = try harness.nextClientMessage(&buffer);
    try std.testing.expect(before_snapshot == .pane_resize);
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, before_snapshot.pane_resize.pane_id);
    try std.testing.expectEqual(initial_request_id, client.model.request_lifecycle.next_request_id);
    try std.testing.expect(!client.model.request_lifecycle.tracker.hasPane(.attachment, sibling));

    _ = try data.tab_snapshot_reconciliation.reconcileTab(
        &client.model,
        .{
            .location = client.model.tabs.location[tab],
            .panes = &.{
                ClientHarness.bootstrap_pane,
                sibling,
            },
        },
        client.geometry().area,
    );
    _ = try resizeHost(
        client,
        .{
            .cols = 100,
            .rows = 30,
            .width_px = 1000,
            .height_px = 600,
        },
    );
    try harness.settle();
    const resized = try harness.nextClientMessage(&buffer);
    try std.testing.expect(resized == .pane_resize);
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, resized.pane_resize.pane_id);
    const opened = try harness.nextClientMessage(&buffer);
    try std.testing.expect(opened == .open_pane);
    try std.testing.expectEqual(sibling, opened.open_pane.target.pane);
    try std.testing.expectEqualDeep(data.tab_layout.contentSize(&client.model, tab, sibling, client.geometry().area).?, opened.open_pane.size);
    try std.testing.expect(client.model.request_lifecycle.tracker.hasPane(.attachment, sibling));
    const pending_request_id = client.model.request_lifecycle.next_request_id;

    _ = try resizeHost(
        client,
        .{
            .cols = 110,
            .rows = 32,
            .width_px = 1100,
            .height_px = 640,
        },
    );
    try harness.settle();
    const repeated = try harness.nextClientMessage(&buffer);
    try std.testing.expect(repeated == .pane_resize);
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, repeated.pane_resize.pane_id);
    try std.testing.expectEqual(pending_request_id, client.model.request_lifecycle.next_request_id);
}

test "host resize rolls back rejected attachment correlation after offering connected pane sizes" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const sibling: core.PaneId = @enumFromInt(20);
    _ = try data.tab_snapshot_reconciliation.reconcileTab(
        &client.model,
        .{
            .location = ClientHarness.bootstrap_location,
            .panes = &.{
                ClientHarness.bootstrap_pane,
                sibling,
            },
        },
        client.geometry().area,
    );

    while (client.model.to_runtime.len < data.outbox_support.capacity - 1) {
        try client.model.to_runtime.push(
            .{
                .detach_pane = .{
                    .pane_id = ClientHarness.bootstrap_pane,
                },
            },
        );
    }

    const initial_request_id = client.model.request_lifecycle.next_request_id;
    try std.testing.expectError(error.ClientOutboxFull, resizeHost(
        client,
        .{
            .cols = 100,
            .rows = 30,
            .width_px = 1000,
            .height_px = 600,
        },
    ));

    try std.testing.expectEqual(initial_request_id + 1, client.model.request_lifecycle.next_request_id);
    try std.testing.expect(!client.model.request_lifecycle.tracker.hasPane(.attachment, sibling));
    try std.testing.expectEqual(@as(usize, data.outbox_support.capacity), client.model.to_runtime.len);
    try std.testing.expectEqual(@as(u16, 100), client.model.host.host_size.cols);
    try std.testing.expect(!client.model.panes.find(sibling).?.attached);
}

test "oversized host measurement changes neither model nor capabilities" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const host_size = client.model.host.host_size;
    const capabilities = client.model.host.host_capabilities;

    try std.testing.expectError(error.ScreenTooLarge, resizeHost(client, .{
        .cols = std.math.maxInt(u16),
        .rows = std.math.maxInt(u16),
        .width_px = 1200,
        .height_px = 800,
    }));

    try std.testing.expectEqualDeep(host_size, client.model.host.host_size);
    try std.testing.expectEqualDeep(capabilities, client.model.host.host_capabilities);
    try std.testing.expectEqualDeep(data.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "pane viewport intent commits before IPC and presenter-owned recomposition" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pane = client.model.panes.find(ClientHarness.bootstrap_pane).?;
    _ = try harness.addInactiveTab(@enumFromInt(2), @enumFromInt(20));
    const active = client.model.tabs.active;
    pane.scroll = .{
        .total_rows = @as(u32, pane.buffer.h) + 10,
        .offset = 10,
    };
    const version = client.model.version();
    const pane_view = data.tab_layout.view(&client.model, active, pane.id, client.geometry().area).?;
    _ = try client_module.pointer_routing.apply(client, .{
        .x = pane_view.content.x,
        .y = pane_view.content.y,
        .kind = .move,
    });

    _ = try client_module.pointer_routing.apply(client, .{
        .x = pane_view.content.x,
        .y = pane_view.content.y,
        .kind = .scroll_up,
    });

    try std.testing.expectEqual(@as(u32, 7), pane.scroll.offset);
    try std.testing.expect(client.graphics.paneVisible(pane.id));

    try keys.routeChord(client, "x");

    try std.testing.expectEqual(@as(u32, 10), pane.scroll.offset);
    try std.testing.expect(client.graphics.paneVisible(pane.id));
    try std.testing.expectEqual(version.viewport + 2, client.model.version().viewport);
    try fixtures.expectNonViewportVersionEqual(version, client.model.version());

    try harness.settle();
    var buffer: [256]u8 = undefined;
    const scrolled = try harness.nextClientMessage(&buffer);
    try std.testing.expect(scrolled == .set_pane_viewport);
    try std.testing.expectEqual(pane.id, scrolled.set_pane_viewport.pane_id);
    try std.testing.expectEqual(@as(u32, 7), scrolled.set_pane_viewport.offset);
    const restored = try harness.nextClientMessage(&buffer);
    try std.testing.expect(restored == .set_pane_viewport);
    try std.testing.expectEqual(pane.id, restored.set_pane_viewport.pane_id);
    try std.testing.expectEqual(@as(u32, 10), restored.set_pane_viewport.offset);
    const input = try harness.nextClientMessage(&buffer);
    try std.testing.expect(input == .pane_input);
    try std.testing.expectEqual(pane.id, input.pane_input.pane_id);
    try std.testing.expectEqualStrings("x", input.pane_input.bytes);

    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.delivered.model);
}

test "native scroll actions reuse bounded viewport delivery without forwarding input" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pane = client.model.panes.find(ClientHarness.bootstrap_pane).?;
    pane.scroll = .{ .total_rows = @as(u32, pane.buffer.h) + 10, .offset = 10 };
    const version = client.model.version();

    for (0..4) |_| {
        _ = try client_module.actions.executeAction(client, try data.Action.parse("scroll-pane-up"), .effect);
    }

    try std.testing.expectEqual(@as(u32, 0), pane.scroll.offset);
    _ = try client_module.actions.executeAction(
        client,
        .{
            .scroll_pane = .up,
        },
        .effect,
    );

    for (0..4) |_| {
        _ = try client_module.actions.executeAction(client, try data.Action.parse("scroll-pane-down"), .effect);
    }

    _ = try client_module.actions.executeAction(
        client,
        .{
            .scroll_pane = .down,
        },
        .effect,
    );
    try std.testing.expectEqual(@as(u32, 10), pane.scroll.offset);
    try std.testing.expectEqual(version.viewport + 8, client.model.version().viewport);
    try fixtures.expectNonViewportVersionEqual(version, client.model.version());

    try harness.settle();
    var buffer: [256]u8 = undefined;
    for ([_]u32{ 7, 4, 1, 0, 3, 6, 9, 10 }) |offset| {
        const message = try harness.nextClientMessage(&buffer);
        try std.testing.expect(message == .set_pane_viewport);
        try std.testing.expectEqual(pane.id, message.set_pane_viewport.pane_id);
        try std.testing.expectEqual(offset, message.set_pane_viewport.offset);
    }
}

test "a full outbox preserves the committed pane viewport and rejects input" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pane = client.model.panes.find(ClientHarness.bootstrap_pane).?;
    pane.scroll = .{
        .total_rows = @as(u32, pane.buffer.h) + 10,
        .offset = 0,
    };
    while (client.model.to_runtime.hasCapacity()) {
        try client.model.to_runtime.push(.{ .detach_pane = .{ .pane_id = pane.id } });
    }

    const version = client.model.version();

    try std.testing.expectError(error.ClientOutboxFull, keys.routeChord(client, "x"));

    try std.testing.expectEqual(@as(u32, 10), pane.scroll.offset);
    try std.testing.expectEqual(version.viewport + 1, client.model.version().viewport);
    try fixtures.expectNonViewportVersionEqual(version, client.model.version());
}

test "copy mode round trip: enter, select, copy, leave" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pane = client.model.panes.find(ClientHarness.bootstrap_pane).?;
    pane.scroll = .{ .total_rows = 30, .offset = 6 };
    pane.cursor = .{ .visible = true, .x = 0, .y = 0 };
    const version_before = client.model.version();

    try std.testing.expectEqual(
        keyinput.Control.continue_routing,
        try client_module.actions.executeAction(client, .enter_copy_mode, .effect),
    );
    try std.testing.expect(data.copy_mode.isActive(&client.model));
    try std.testing.expect(!data.key_routing.captures(client_module.key_routing.keyRoutingAuthority(client)));
    try std.testing.expect(!client_module.name_prompt.openNamePrompt(&client.model, .rename_active_tab));
    try std.testing.expect(!client.model.name_prompt.active());
    try fixtures.expectNonCopyVersionEqual(version_before, client.model.version());
    try std.testing.expectEqual(version_before.copy + 1, client.model.version().copy);

    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(
        data.copy_mode.currentProjection(&client.model).?.view,
        harness.presentedCopy().?.view,
    );
    const painted_cursor_y = harness.presentedCopy().?.view.cursor.y;

    const pane_view = data.tab_layout.view(
        &client.model,
        client.model.tabs.active,
        pane.id,
        client.geometry().area,
    ).?;
    const mouse_version = client.model.version();
    _ = try client_module.pointer_routing.apply(client, .{
        .x = pane_view.content.x,
        .y = pane_view.content.y,
        .kind = .press,
    });
    try std.testing.expectEqualDeep(mouse_version, client.model.version());
    _ = try client_module.pointer_routing.apply(client, .{
        .x = pane_view.content.x,
        .y = pane_view.content.y,
        .kind = .scroll_up,
    });
    try std.testing.expectEqual(mouse_version.copy + 1, client.model.version().copy);
    try std.testing.expectEqual(mouse_version.viewport + 1, client.model.version().viewport);
    try fixtures.expectNonCopyOrViewportVersionEqual(mouse_version, client.model.version());
    try std.testing.expectEqual(painted_cursor_y - 3, data.copy_mode.currentProjection(&client.model).?.view.cursor.y);

    // While in copy mode, keys route to the selection, not the pane.
    try keys.routeChord(client, "v");
    try keys.routeChord(client, "l");
    try harness.settleModelPresentation();
    try std.testing.expectEqual(@as(u16, 1), harness.presentedCopy().?.view.cursor.x);
    try std.testing.expect(harness.presentedCopy().?.view.anchor != null);

    const version_before_copy = client.model.version();
    try keys.routeChord(client, "enter");
    try std.testing.expect(!data.copy_mode.isActive(&client.model));
    try fixtures.expectNonCopyOrViewportVersionEqual(version_before_copy, client.model.version());
    try std.testing.expectEqual(version_before_copy.copy + 1, client.model.version().copy);
    try std.testing.expectEqual(version_before_copy.viewport + 1, client.model.version().viewport);
    try harness.settleModelPresentation();
    try std.testing.expect(harness.presentedCopy() == null);
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.delivered.model);
    try harness.settle();

    var buffer: [256]u8 = undefined;
    var copied = false;
    while (!copied) {
        switch (try harness.nextClientMessage(&buffer)) {
            .copy_selection => |selection| {
                try std.testing.expectEqual(ClientHarness.bootstrap_pane, selection.pane_id);
                try std.testing.expectEqual(@as(u16, 1), selection.end_x);
                copied = true;
            },
            .set_pane_viewport, .pane_input => {},
            else => return error.UnexpectedClientMessage,
        }
    }
}

test "copy-mode o opens a file URI in an editor tab without leaving the mode" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.options.editor = "nvim";
    const pane = client.model.panes.find(ClientHarness.bootstrap_pane).?;
    pane.buffer.fill(pane.buffer.area(), .{ .glyph = " ", .style = .{} });
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "file:///tmp/a%20b.txt", .style = .{} });
    pane.cursor = .{ .visible = true, .x = 12, .y = 0 };

    _ = try client_module.actions.executeAction(client, .enter_copy_mode, .effect);
    const version = client.model.version();
    try keys.routeChord(client, "o");

    try std.testing.expect(data.copy_mode.isActive(&client.model));
    try std.testing.expectEqualDeep(version, client.model.version());
    try harness.settle();

    var buffer: [512]u8 = undefined;
    // The editor opens in a split beside the link's pane: the pane gives up
    // its space first, then the editor pane is created.
    const resized = try harness.nextClientMessage(&buffer);
    try std.testing.expect(resized == .pane_resize);
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, resized.pane_resize.pane_id);
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .create_pane);
    var arguments = message.create_pane.launch.arguments();
    try std.testing.expectEqualStrings("nvim", (try arguments.next()).?);
    try std.testing.expectEqualStrings("/tmp/a b.txt", (try arguments.next()).?);
    try std.testing.expect(try arguments.next() == null);
}

test "a left click opens a file URI and owns the complete mouse gesture" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.options.editor = "nvim";
    const pane = client.model.panes.find(ClientHarness.bootstrap_pane).?;
    pane.buffer.fill(pane.buffer.area(), .{ .glyph = " ", .style = .{} });
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "file:///tmp/click.txt", .style = .{} });
    const pane_view = data.tab_layout.view(
        &client.model,
        client.model.tabs.active,
        pane.id,
        client.geometry().area,
    ).?;

    _ = try client_module.pointer_routing.apply(client, .{
        .x = pane_view.content.x + 10,
        .y = pane_view.content.y,
        .kind = .press,
        .button = 0,
    });
    try std.testing.expect(client.model.link_pointer.owned);
    _ = try client_module.pointer_routing.apply(client, .{
        .x = pane_view.content.x + 10,
        .y = pane_view.content.y,
        .kind = .release,
        .button = 0,
    });
    try std.testing.expect(!client.model.link_pointer.owned);
    try harness.settle();

    var buffer: [512]u8 = undefined;
    // The editor opens in a split beside the link's pane: the pane gives up
    // its space first, then the editor pane is created.
    const resized = try harness.nextClientMessage(&buffer);
    try std.testing.expect(resized == .pane_resize);
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, resized.pane_resize.pane_id);
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .create_pane);
    var arguments = message.create_pane.launch.arguments();
    try std.testing.expectEqualStrings("nvim", (try arguments.next()).?);
    try std.testing.expectEqualStrings("/tmp/click.txt", (try arguments.next()).?);
    try std.testing.expect(try arguments.next() == null);
}

test "native action preflight retires copy mode before concrete delivery" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try client_module.actions.executeAction(client, .enter_copy_mode, .effect);
    const version = client.model.version();

    try std.testing.expect(data.copy_mode.isActive(&client.model));
    try std.testing.expect(client.model.sidebar_visible);
    try std.testing.expectEqual(
        keyinput.Control.continue_routing,
        try client_module.actions.executeAction(client, .toggle_sidebar, .effect),
    );

    var expected = version;
    expected.copy += 1;
    expected.chrome += 1;
    try std.testing.expect(!data.copy_mode.isActive(&client.model));
    try std.testing.expect(!client.model.sidebar_visible);
    try std.testing.expectEqualDeep(expected, client.model.version());
}

test "copy-mode pointer consumes outside wheels and exits a missing target" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try client_module.actions.executeAction(client, .enter_copy_mode, .effect);
    const active_version = client.model.version();

    _ = try client_module.pointer_routing.apply(client, .{
        .x = std.math.maxInt(u16),
        .y = std.math.maxInt(u16),
        .kind = .scroll_up,
    });

    try std.testing.expect(data.copy_mode.isActive(&client.model));
    try std.testing.expectEqualDeep(active_version, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);

    try std.testing.expect(data.tab_layout.removePane(&client.model, ClientHarness.bootstrap_pane));
    _ = try client_module.pointer_routing.apply(client, .{ .x = 0, .y = 0, .kind = .move });

    try std.testing.expect(!data.copy_mode.isActive(&client.model));
    try fixtures.expectNonCopyVersionEqual(active_version, client.model.version());
    try std.testing.expectEqual(active_version.copy + 1, client.model.version().copy);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "a full outbox keeps copy mode and its selection active" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    while (client.model.to_runtime.hasCapacity()) {
        try client.model.to_runtime.push(.{ .detach_pane = .{ .pane_id = ClientHarness.bootstrap_pane } });
    }

    _ = try client_module.actions.executeAction(client, .enter_copy_mode, .effect);
    try keys.routeChord(client, "v");
    const version = client.model.version();

    try std.testing.expectError(error.ClientOutboxFull, keys.routeChord(client, "enter"));

    try std.testing.expect(data.copy_mode.isActive(&client.model));
    try std.testing.expect(data.copy_mode.currentProjection(&client.model).?.view.anchor != null);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(data.outbox_support.capacity, @as(usize, client.model.to_runtime.len));
}

/// Applies one measured host size as a window reports it: its pixels
/// resolve the cell size.
/// Example: `_ = try resizeHost(client, measurement);`
fn resizeHost(client: *client_module.Client, measurement: Measurement) !?data.HostCommit {
    var capabilities = client.model.host.host_capabilities;
    capabilities.window_width_px = measurement.width_px;
    capabilities.window_height_px = measurement.height_px;
    const cell_size = capabilities.cellSize(measurement.cols, measurement.rows);

    return client_module.host_resize.applyHostUpdate(client, .{
        .capabilities = capabilities,
        .size = .{
            .cols = measurement.cols,
            .rows = measurement.rows,
            .cell_width_px = cell_size.width,
            .cell_height_px = cell_size.height,
        },
    });
}

/// Presents the model and checks the presentation carried its version.
fn expectPresented(harness: *ClientHarness) !void {
    try harness.present();
    try std.testing.expectEqualDeep(harness.client.model.version(), harness.client.presentation.delivered.model);
}

