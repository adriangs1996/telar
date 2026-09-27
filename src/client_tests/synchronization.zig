//! Synchronization with the runtime through the shared client: request
//! correlation, tab and workspace snapshots, workspace handoff and resync.
//! A frame the model asks for is counted by the presentation tokens the
//! harness takes when it presents.
const keyinput = @import("keyinput");
const core = @import("telar-core");
const client_module = @import("telar-client");
const data = @import("model");
const ClientHarness = @import("ClientHarness.zig");
const RetainedGraphics = @import("RetainedGraphics.zig");
const std = @import("std");
const fixtures = @import("fixtures.zig");

test "pane opening rejects an unknown request without client effects" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const version_before = client.model.version();
    const frames_before = preparedFrames(&harness);

    try std.testing.expectError(error.UnexpectedRequest, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .pane_opened = .{
                .request_id = @enumFromInt(99),
                .pane_id = ClientHarness.bootstrap_pane,
                .location = ClientHarness.bootstrap_location,
                .created = true,
            },
        },
    ));

    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(frames_before, preparedFrames(&harness));
}

test "pane opening consumes an incompatible continuation before rejection" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: core.RequestId = @enumFromInt(4);
    const opened: core.PaneOpened = .{
        .request_id = request_id,
        .pane_id = ClientHarness.bootstrap_pane,
        .location = ClientHarness.bootstrap_location,
        .created = true,
    };
    const version_before = client.model.version();
    const frames_before = preparedFrames(&harness);
    try client.model.request_lifecycle.tracker.add(request_id, .notification);

    try std.testing.expectError(error.UnexpectedRequest, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .pane_opened = opened,
        },
    ));
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedRequest, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .pane_opened = opened,
        },
    ));
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(frames_before, preparedFrames(&harness));
}

test "pane opening consumes an ignored continuation without client effects" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: core.RequestId = @enumFromInt(4);
    const version_before = client.model.version();
    const frames_before = preparedFrames(&harness);
    try client.model.request_lifecycle.tracker.add(request_id, .ignored);

    try std.testing.expectEqual(@as(?u8, null), try client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .pane_opened = .{
                .request_id = request_id,
                .pane_id = ClientHarness.bootstrap_pane,
                .location = ClientHarness.bootstrap_location,
                .created = false,
            },
        },
    ));

    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(frames_before, preparedFrames(&harness));
}

test "new tab request captures launch source geometry and continuation without mutation" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    harness.client.options.arguments = &.{"/bin/sh"};
    const version_before_request = harness.client.model.version();
    const frames_before_request = preparedFrames(&harness);

    _ = try client_module.actions.executeAction(harness.client, .new_tab, .effect);
    try harness.settle();

    var buffer: [512]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .create_tab);
    const created = message.create_tab;
    try std.testing.expectEqualDeep(ClientHarness.bootstrap_location.workspace, created.workspace);
    try std.testing.expectEqualStrings("", created.label);
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, created.launch.cwd_source.?);
    try std.testing.expectEqual(core.TerminalSize{
        .cols = harness.client.geometry().area.w,
        .rows = harness.client.geometry().area.h,
    }, created.size);
    try std.testing.expectEqualDeep(version_before_request, harness.client.model.version());
    try std.testing.expectEqual(frames_before_request, preparedFrames(&harness));

    const continuation = harness.client.model.request_lifecycle.tracker.take(created.request_id).?;
    try std.testing.expect(continuation == .create_tab);
    try std.testing.expectEqualDeep(created.workspace, continuation.create_tab.workspace);
    try std.testing.expectEqual(created.size, continuation.create_tab.size);
}

test "new pane inherits cwd from the focused runtime pane" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    harness.client.options.arguments = &.{"/bin/sh"};

    _ = try client_module.actions.executeAction(
        harness.client,
        .{
            .split_pane = .horizontal,
        },
        .effect,
    );
    try harness.settle();

    var buffer: [512]u8 = undefined;
    try std.testing.expect((try harness.nextClientMessage(&buffer)) == .pane_resize);
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .create_pane);
    const created = message.create_pane;
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, created.launch.cwd_source.?);
}

test "new workspace inherits cwd from the focused runtime pane" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    harness.client.options.arguments = &.{"/bin/sh"};
    harness.client.model.request_lifecycle.tracker = .{};

    _ = try client_module.actions.executeAction(harness.client, .new_workspace, .effect);
    try typeText(&harness, "agents");
    try pressKey(&harness, .plain(.enter));
    try harness.settle();

    var buffer: [512]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .create_workspace);
    const created = message.create_workspace;
    try std.testing.expectEqualStrings("agents", created.name);
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, created.launch.cwd_source.?);
}

test "workspace handoff opens the pane remembered for that workspace" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};

    const destination: core.WorkspaceLocation = .{ .workspace = @enumFromInt(2) };
    const restored_pane: core.PaneId = @enumFromInt(77);
    client.model.navigation_history.remember(.{
        .location = .{ .workspace = destination, .tab_id = @enumFromInt(8) },
        .pane_id = restored_pane,
    });
    const version_before_departure = client.model.version();
    const frames_before_departure = preparedFrames(&harness);
    _ = try client_module.workspace_handoff.requestWorkspace(client, @enumFromInt(2));

    try std.testing.expect(client.model.workspace == null);
    try std.testing.expectEqual(@as(usize, 0), client.model.tabs.count);
    try std.testing.expectEqual(version_before_departure.workspace + 1, client.model.version().workspace);
    try std.testing.expectEqual(version_before_departure.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_departure.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(version_before_departure.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(frames_before_departure, preparedFrames(&harness));
    try std.testing.expect(client.model.reported_pane_focus == null);

    try harness.present();

    try std.testing.expectEqual(frames_before_departure + 1, preparedFrames(&harness));
    try harness.settleModelPresentation();
    try harness.settle();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);
    try std.testing.expect(!client.presentation.needsPreparation());
    const frames_settled = preparedFrames(&harness);
    try harness.present();
    try std.testing.expectEqual(frames_settled, preparedFrames(&harness));

    var buffer: [256]u8 = undefined;
    var target: ?core.PaneTarget = null;
    var request_id: core.RequestId = .none;
    while (target == null) switch (try harness.nextClientMessage(&buffer)) {
        .detach_pane => {},
        .open_pane => |open| {
            request_id = open.request_id;
            target = open.target;
        },
        else => return error.UnexpectedClientMessage,
    };
    try std.testing.expectEqualDeep(core.PaneTarget{ .pane = restored_pane }, target.?);
    const current = client.model.navigation_history.find(ClientHarness.bootstrap_location.workspace).?;
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, current.pane_id);
    try std.testing.expect(current.tab_layout != null);

    var payload: [128]u8 = undefined;
    const failed = try core.encodeRequestFailed(&payload, .{
        .request_id = request_id,
        .code = .pane_not_found,
        .message = "remembered pane closed",
    });
    const version_before_recovery = client.model.version();
    const frames_before_recovery = preparedFrames(&harness);
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(failed));

    try std.testing.expectEqualDeep(version_before_recovery, client.model.version());
    try std.testing.expectEqual(frames_before_recovery, preparedFrames(&harness));
    try harness.settle();
    const fallback = (try harness.nextClientMessage(&buffer)).open_pane;
    try std.testing.expectEqualDeep(
        core.PaneTarget{ .workspace = @enumFromInt(2) },
        fallback.target,
    );
    const retry = client.model.request_lifecycle.tracker.take(fallback.request_id).?;
    try std.testing.expect(retry == .initial_open);
    try std.testing.expect(retry.initial_open.fallback_workspace == null);
    try std.testing.expect(client.model.navigation_history.find(destination) == null);
}

test "workspace handoff capacity failure preserves the source model" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    while (client.model.to_runtime.len < data.outbox_support.capacity - 1) {
        try client.model.to_runtime.push(.{ .detach_pane = .{ .pane_id = ClientHarness.bootstrap_pane } });
    }
    const version_before = client.model.version();
    const focus_before = client.model.reported_pane_focus;
    const next_request_id = client.model.request_lifecycle.next_request_id;

    try std.testing.expectError(
        error.ClientOutboxFull,
        client_module.workspace_handoff.requestWorkspace(client, @enumFromInt(2)),
    );

    try std.testing.expectEqualDeep(ClientHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expect(client.model.panes.find(ClientHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqualDeep(focus_before, client.model.reported_pane_focus);
    try std.testing.expect(client.model.navigation_history.find(ClientHarness.bootstrap_location.workspace) == null);
    try std.testing.expectEqual(next_request_id, client.model.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqual(data.outbox_support.capacity - 1, @as(usize, client.model.to_runtime.len));
}

test "workspace handoff request exhaustion preserves the source model" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    client.model.request_lifecycle.next_request_id = std.math.maxInt(u64) - 1;
    const version_before = client.model.version();
    const focus_before = client.model.reported_pane_focus;
    const outbox_len = client.model.to_runtime.len;

    try std.testing.expectError(
        error.RequestIdExhausted,
        client_module.workspace_handoff.requestWorkspace(client, @enumFromInt(2)),
    );

    try std.testing.expectEqualDeep(ClientHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expect(client.model.panes.find(ClientHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqualDeep(focus_before, client.model.reported_pane_focus);
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, client.model.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqual(outbox_len, client.model.to_runtime.len);
}

test "workspace handoff reserves its focus-out message" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    client.model.panes.find(ClientHarness.bootstrap_pane).?.input_modes.focus_events = true;
    try client_module.pane_focus.synchronizeActivePane(client);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const focus_in = try harness.nextClientMessage(&buffer);
    try std.testing.expect(focus_in == .pane_input);
    try std.testing.expectEqualStrings("\x1b[I", focus_in.pane_input.bytes);
    while (client.model.to_runtime.len < data.outbox_support.capacity - 2) {
        try client.model.to_runtime.push(.{ .detach_pane = .{ .pane_id = ClientHarness.bootstrap_pane } });
    }
    const version = client.model.version();
    const reported = client.model.reported_pane_focus;

    try std.testing.expectError(
        error.ClientOutboxFull,
        client_module.workspace_handoff.requestWorkspace(client, @enumFromInt(2)),
    );

    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqualDeep(reported, client.model.reported_pane_focus);
    try std.testing.expect(client.model.panes.find(ClientHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqualDeep(ClientHarness.bootstrap_location, client.model.activeTabLocation().?);
}

test "workspace handoff reserves its captured paste closing marker" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    client.model.panes.find(ClientHarness.bootstrap_pane).?.input_modes.bracketed_paste = true;
    _ = try client_module.paste_routing.start(client);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const opening = try harness.nextClientMessage(&buffer);
    try std.testing.expect(opening == .pane_input);
    try std.testing.expectEqualStrings("\x1b[200~", opening.pane_input.bytes);
    while (client.model.to_runtime.len < data.outbox_support.capacity - 2) {
        try client.model.to_runtime.push(.{ .detach_pane = .{ .pane_id = ClientHarness.bootstrap_pane } });
    }
    const version = client.model.version();

    try std.testing.expectError(
        error.ClientOutboxFull,
        client_module.workspace_handoff.requestWorkspace(client, @enumFromInt(2)),
    );

    try std.testing.expect(data.pane_input.pasteActive(&client.model));
    try std.testing.expectEqualDeep(ClientHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expect(client.model.panes.find(ClientHarness.bootstrap_pane).?.attached);
}

test "clicking a sidebar agent hands off directly to its pane" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};

    const agent_pane: core.PaneId = @enumFromInt(91);
    const agent = data.AgentInput{
        .key = .{ .pane_id = agent_pane, .pane_generation = 2 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(3) },
            .tab_id = @enumFromInt(6),
        },
        .pane_index = 2,
        .provider = .claude,
        .status = .working,
    };
    const left_pane: core.PaneId = @enumFromInt(90);
    const bottom_right_pane: core.PaneId = @enumFromInt(92);
    var saved_layout: data.WorkspaceLayout = .{};
    try saved_layout.addRoot(left_pane);
    try saved_layout.split(.{ .existing_pane = left_pane, .new_pane = agent_pane, .axis = .horizontal });
    try saved_layout.split(.{ .existing_pane = agent_pane, .new_pane = bottom_right_pane, .axis = .vertical });
    try std.testing.expect(saved_layout.toggleFullscreen());
    client.model.navigation_history.remember(.{
        .location = agent.location,
        .pane_id = bottom_right_pane,
        .tab_layout = saved_layout,
    });
    _ = try data.agent_snapshot.reconcile(&client.model, .{
        .revision = 1,
        .agents = &.{agent},
    });
    // The interaction a click on the agent's sidebar row emits.
    _ = try client_module.view_interactions.apply(client, client.model.tabs.active, .{
        .intent = .{
            .focus_agent = agent.key,
        },
    });
    try harness.settle();

    var buffer: [256]u8 = undefined;
    var target: ?core.PaneTarget = null;
    var request_id: core.RequestId = .none;
    while (target == null) switch (try harness.nextClientMessage(&buffer)) {
        .detach_pane => {},
        .open_pane => |open| {
            request_id = open.request_id;
            target = open.target;
        },
        else => return error.UnexpectedClientMessage,
    };
    try std.testing.expectEqualDeep(core.PaneTarget{ .pane = agent_pane }, target.?);

    var payload: [128]u8 = undefined;
    const opened = try core.encodePaneOpened(&payload, .{
        .request_id = request_id,
        .pane_id = agent_pane,
        .location = agent.location,
        .created = false,
    });
    const version_before_arrival = client.model.version();
    const frames_before_arrival = preparedFrames(&harness);
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(opened));

    try std.testing.expectEqual(version_before_arrival.workspace + 1, client.model.version().workspace);
    try std.testing.expectEqual(version_before_arrival.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_arrival.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(version_before_arrival.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(frames_before_arrival, preparedFrames(&harness));

    try harness.present();

    try std.testing.expectEqual(frames_before_arrival + 1, preparedFrames(&harness));
    try harness.settleModelPresentation();
    try harness.settle();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);
    try std.testing.expectEqualDeep(
        @as(?core.WorkspaceLocation, agent.location.workspace),
        client.model.workspace,
    );
    try std.testing.expectEqual(agent.location.tab_id, client.model.tabs.location[client.model.tabs.active].tab_id);
    try std.testing.expectEqual(agent_pane, client.model.tabs.layout[client.model.tabs.active].focused().?);

    var tab_snapshot_request: core.RequestId = .none;
    while (tab_snapshot_request == .none) switch (try harness.nextClientMessage(&buffer)) {
        .request_workspace_snapshot => {},
        .request_tab_snapshot => |request| {
            try std.testing.expectEqualDeep(agent.location, request.location);
            tab_snapshot_request = request.request_id;
        },
        else => return error.UnexpectedClientMessage,
    };
    var snapshot_payload: [256]u8 = undefined;
    const snapshot = try core.encodeTabSnapshot(&snapshot_payload, .{
        .request_id = tab_snapshot_request,
        .location = agent.location,
        .panes = &.{
            .{ .pane_id = left_pane, .lifecycle = .running },
            .{ .pane_id = agent_pane, .lifecycle = .running },
            .{ .pane_id = bottom_right_pane, .lifecycle = .running },
        },
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(snapshot));

    const restored = client.model.tabs.active;
    try std.testing.expectEqual(agent_pane, client.model.tabs.layout[restored].focused().?);
    try std.testing.expect(client.model.tabs.layout[restored].isFullscreen());
    try std.testing.expectEqual(@as(u16, 2), client.model.tabs.layout[restored].displayIndex(agent_pane).?);
    var expected_geometry: data.LayoutSnapshot = .{};
    var actual_geometry: data.LayoutSnapshot = .{};
    var actual_tiled = client.model.tabs.layout[restored];
    try std.testing.expect(saved_layout.toggleFullscreen());
    try std.testing.expect(actual_tiled.toggleFullscreen());
    saved_layout.snapshot(client.geometry().area, &expected_geometry);
    actual_tiled.snapshot(client.geometry().area, &actual_geometry);
    for ([_]core.PaneId{ left_pane, agent_pane, bottom_right_pane }) |pane_id|
        try std.testing.expectEqual(
            expected_geometry.find(pane_id).?.outer,
            actual_geometry.find(pane_id).?.outer,
        );
}

test "sidebar workspace round trip restores fullscreen in a previously inactive tab" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    const first = ClientHarness.bootstrap_pane;
    const clicked: core.PaneId = @enumFromInt(21);
    const area = client.geometry().area;
    _ = try data.tab_snapshot_reconciliation.reconcileTab(&client.model, .{ .location = ClientHarness.bootstrap_location, .panes = &.{first} }, area);
    const fullscreen_tab = client.model.tabs.active;
    try data.pane_split.split(&client.model, fullscreen_tab, .{ .existing_pane = first, .new_pane = clicked, .location = ClientHarness.bootstrap_location, .axis = .vertical, .area = area });
    try std.testing.expect(client.model.tabs.layout[fullscreen_tab].focusPane(first));
    try std.testing.expect(client.model.tabs.layout[fullscreen_tab].resizeFocused(.down, area));
    try std.testing.expect(client.model.tabs.layout[fullscreen_tab].toggleFullscreen());
    var original_nodes: [core.max_client_layout_nodes]core.ClientLayoutNode = undefined;
    const expected = client.model.tabs.layout[fullscreen_tab].clientLayoutNodes(&original_nodes);
    const other_location = try harness.addTab(@enumFromInt(2), @enumFromInt(20));
    try std.testing.expectEqual(other_location, client.model.activeTabLocation().?);
    const destinations = [_]data.AgentInput{
        .{
            .key = .{ .pane_id = @enumFromInt(99), .pane_generation = 1 },
            .location = .{ .workspace = .{ .workspace = @enumFromInt(3) }, .tab_id = @enumFromInt(6) },
            .pane_index = 1,
            .provider = .claude,
            .status = .working,
        },
        .{
            .key = .{ .pane_id = clicked, .pane_generation = 1 },
            .location = ClientHarness.bootstrap_location,
            .pane_index = 2,
            .provider = .codex,
            .status = .working,
        },
    };
    _ = try data.agent_snapshot.reconcile(&client.model, .{ .revision = 1, .agents = &destinations });

    for (destinations, 0..) |agent, turn| {
        try std.testing.expectEqual(.handoff_requested, try client_module.agent_navigation.navigateAgent(client, agent.key));
        try harness.settle();
        var buffer: [512]u8 = undefined;
        var open_id: core.RequestId = .none;
        while (open_id == .none) {
            switch (try harness.nextClientMessage(&buffer)) {
                .open_pane => |open| {
                    try std.testing.expectEqualDeep(core.PaneTarget{ .pane = agent.key.pane_id }, open.target);
                    open_id = open.request_id;
                },
                .detach_pane, .pane_resize => {},
                else => return error.UnexpectedClientMessage,
            }
        }

        const opened = try core.encodePaneOpened(&buffer, .{
            .request_id = open_id,
            .pane_id = agent.key.pane_id,
            .location = agent.location,
            .created = false,
        });
        _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(opened));
        try harness.settle();
        var workspace_request: core.RequestId = .none;
        var tab_request: core.RequestId = .none;
        while (workspace_request == .none or tab_request == .none) {
            switch (try harness.nextClientMessage(&buffer)) {
                .request_workspace_snapshot => |request| workspace_request = request.request_id,
                .request_tab_snapshot => |request| tab_request = request.request_id,
                else => return error.UnexpectedClientMessage,
            }
        }

        const tabs = [_]core.TabDescriptor{
            .{ .tab_id = agent.location.tab_id, .position = 0, .pane_count = if (turn == 0) 1 else 2, .label = "main" },
            .{ .tab_id = other_location.tab_id, .position = 1, .pane_count = 1, .label = "other" },
        };
        const workspace_snapshot = try core.encodeWorkspaceSnapshot(&buffer, .{
            .request_id = workspace_request,
            .workspace = agent.location.workspace,
            .name = "workspace",
            .tabs = tabs[0..if (turn == 0) @as(usize, 1) else 2],
        });
        _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(workspace_snapshot));
        const panes = [_]core.PaneDescriptor{
            .{ .pane_id = agent.key.pane_id, .lifecycle = .running },
            .{ .pane_id = first, .lifecycle = .running },
        };
        const tab_snapshot = try core.encodeTabSnapshot(&buffer, .{
            .request_id = tab_request,
            .location = agent.location,
            .panes = panes[0..if (turn == 0) @as(usize, 1) else 2],
        });
        _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(tab_snapshot));
    }

    const restored = client.model.tabs.active;
    try std.testing.expect(client.model.tabs.layout[restored].isFullscreen());
    try std.testing.expectEqual(clicked, client.model.tabs.layout[restored].focused().?);
    var actual_nodes: [core.max_client_layout_nodes]core.ClientLayoutNode = undefined;
    try std.testing.expectEqualDeep(expected, client.model.tabs.layout[restored].clientLayoutNodes(&actual_nodes));
    try std.testing.expectEqual(core.TerminalSize{ .cols = area.w - 2, .rows = area.h - 2 }, data.tab_layout.contentSize(&client.model, restored, clicked, area).?);
    try std.testing.expect(data.tab_layout.contentSize(&client.model, restored, first, area) == null);
    try std.testing.expect(client.model.saved_layouts.find(other_location) != null);
}

test "local agent navigation selects its tab before focusing its pane" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    try harness.allowTabSelection();
    const client = harness.client;
    const agent_pane: core.PaneId = @enumFromInt(20);
    const location = try harness.addInactiveTab(@enumFromInt(2), agent_pane);
    const key: data.AgentKey = .{
        .pane_id = agent_pane,
        .pane_generation = 1,
    };
    _ = try data.agent_snapshot.reconcile(&client.model, .{
        .revision = 1,
        .agents = &.{.{
            .key = key,
            .location = location,
            .pane_index = 1,
            .provider = .codex,
            .status = .working,
        }},
    });
    const version = client.model.version();
    const frames = preparedFrames(&harness);

    try std.testing.expectEqual(
        .focused,
        try client_module.agent_navigation.navigateAgent(client, key),
    );

    try std.testing.expectEqualDeep(location, client.model.activeTabLocation().?);
    try std.testing.expectEqual(agent_pane, client.model.tabs.layout[client.model.tabs.active].focused().?);
    try std.testing.expectEqual(version.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(version.panes, client.model.version().panes);
    try std.testing.expectEqual(frames, preparedFrames(&harness));

    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, detached.detach_pane.pane_id);
    const snapshot = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(snapshot == .request_tab_snapshot);
    try std.testing.expectEqualDeep(location, snapshot.request_tab_snapshot.location);
}

test "local sidebar agent navigation keeps fullscreen when targeting a different pane" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    try harness.allowTabSelection();
    const client = harness.client;
    const first: core.PaneId = @enumFromInt(20);
    const clicked: core.PaneId = @enumFromInt(21);
    const location = try harness.addInactiveTab(@enumFromInt(2), first);
    const tab = client.model.tabs.find(location.tab_id).?;
    const area = client.geometry().area;
    try data.pane_split.split(&client.model, tab, .{ .existing_pane = first, .new_pane = clicked, .location = location, .axis = .vertical, .area = area });
    try std.testing.expect(client.model.tabs.layout[tab].focusPane(first));
    try std.testing.expect(client.model.tabs.layout[tab].toggleFullscreen());
    const key: data.AgentKey = .{ .pane_id = clicked, .pane_generation = 1 };
    _ = try data.agent_snapshot.reconcile(&client.model, .{
        .revision = 1,
        .agents = &.{.{ .key = key, .location = location, .pane_index = 2, .provider = .codex, .status = .working }},
    });

    try std.testing.expectEqual(.focused, try client_module.agent_navigation.navigateAgent(client, key));
    try std.testing.expect(client.model.tabs.layout[tab].isFullscreen());
    try std.testing.expectEqual(clicked, client.model.tabs.layout[tab].focused().?);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    var snapshot_request: core.RequestId = .none;
    while (snapshot_request == .none) {
        switch (try harness.nextClientMessage(&buffer)) {
            .request_tab_snapshot => |request| snapshot_request = request.request_id,
            .detach_pane, .pane_resize, .open_pane => {},
            else => return error.UnexpectedClientMessage,
        }
    }

    const payload = try core.encodeTabSnapshot(&buffer, .{
        .request_id = snapshot_request,
        .location = location,
        .panes = &.{ .{ .pane_id = first, .lifecycle = .running }, .{ .pane_id = clicked, .lifecycle = .running } },
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(payload));
    try std.testing.expect(client.model.tabs.layout[tab].isFullscreen());
    try std.testing.expectEqual(clicked, client.model.tabs.layout[tab].focused().?);
    try std.testing.expect(data.tab_layout.contentSize(&client.model, tab, first, area) == null);
    try std.testing.expectEqual(core.TerminalSize{ .cols = area.w - 2, .rows = area.h - 2 }, data.tab_layout.contentSize(&client.model, tab, clicked, area).?);
}

test "tab snapshots commit pane revisions before attaching and presenting" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const frames_before = preparedFrames(&harness);

    const discovered: core.PaneId = @enumFromInt(11);
    var payload: [256]u8 = undefined;
    const snapshot = try core.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(3),
        .location = ClientHarness.bootstrap_location,
        .panes = &.{
            .{ .pane_id = ClientHarness.bootstrap_pane, .lifecycle = .running },
            .{ .pane_id = discovered, .lifecycle = .running },
        },
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try client_module.runtime_messages.handleServerMessage(
            client,
            .{
                .tab_snapshot = (try core.decodeServer(snapshot)).tab_snapshot,
            },
        ),
    );

    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(version_before.workspace, client.model.version().workspace);
    try std.testing.expectEqual(version_before.tabs, client.model.version().tabs);
    try std.testing.expectEqual(version_before.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(frames_before, preparedFrames(&harness));
    const committed_version = client.model.version();
    try client.model.request_lifecycle.tracker.add(@enumFromInt(90), .{ .tab_snapshot = ClientHarness.bootstrap_location });
    const repeated = try core.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(90),
        .location = ClientHarness.bootstrap_location,
        .panes = &.{
            .{ .pane_id = ClientHarness.bootstrap_pane, .lifecycle = .running },
            .{ .pane_id = discovered, .lifecycle = .running },
        },
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(repeated));

    try std.testing.expectEqualDeep(committed_version, client.model.version());
    try std.testing.expect(client.model.request_lifecycle.tracker.hasPane(.attachment, discovered));
    try std.testing.expectEqual(@as(usize, 2), client.model.request_lifecycle.tracker.count);

    try harness.present();

    try std.testing.expectEqual(frames_before + 1, preparedFrames(&harness));
    try harness.settle();

    const pane = client.model.panes.find(discovered).?;
    try std.testing.expect(!pane.attached);
    var buffer: [256]u8 = undefined;
    var attach_requested = false;
    while (!attach_requested) {
        switch (try harness.nextClientMessage(&buffer)) {
            .open_pane => |open| {
                try std.testing.expectEqualDeep(
                    core.PaneTarget{ .pane = discovered },
                    open.target,
                );
                attach_requested = true;
            },
            .pane_resize => {},
            else => return error.UnexpectedClientMessage,
        }
    }

    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);
}

test "an identical tab snapshot repairs resources without scheduling a frame" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    var payload: [256]u8 = undefined;
    const initial = try core.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(3),
        .location = ClientHarness.bootstrap_location,
        .panes = &.{.{ .pane_id = ClientHarness.bootstrap_pane, .lifecycle = .running }},
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(initial));
    try harness.present();
    try harness.settle();
    try harness.settleModelPresentation();
    const committed_version = client.model.version();
    const frames_before = preparedFrames(&harness);
    try client.model.request_lifecycle.tracker.add(@enumFromInt(90), .{ .tab_snapshot = ClientHarness.bootstrap_location });
    const unchanged = try core.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(90),
        .location = ClientHarness.bootstrap_location,
        .panes = &.{.{ .pane_id = ClientHarness.bootstrap_pane, .lifecycle = .running }},
    });

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(unchanged));
    try harness.present();

    try std.testing.expectEqualDeep(committed_version, client.model.version());
    try std.testing.expectEqual(frames_before, preparedFrames(&harness));
}

test "tab reconciliation retires removed pane resources and continuations" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    var payload: [256]u8 = undefined;
    const initial = try core.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(3),
        .location = ClientHarness.bootstrap_location,
        .panes = &.{.{ .pane_id = ClientHarness.bootstrap_pane, .lifecycle = .running }},
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(initial));
    try harness.settle();

    const retired: core.PaneId = @enumFromInt(11);
    const model = client.model.tabs.active;
    try data.pane_split.split(&client.model, model, .{ .existing_pane = ClientHarness.bootstrap_pane, .new_pane = retired, .location = ClientHarness.bootstrap_location, .axis = .horizontal, .area = client.geometry().area });
    try client_module.pane_focus.synchronizeActivePane(client);
    try std.testing.expect(data.copy_mode.enter(&client.model));
    var images: PaneImages = .{
        .retained = &harness.graphics,
    };
    client.graphics = images.port();
    try images.add(retired);
    try client.model.request_lifecycle.tracker.add(@enumFromInt(91), .{ .close_pane = .{
        .pane_id = retired,
        .location = ClientHarness.bootstrap_location,
    } });
    try client.model.request_lifecycle.tracker.add(@enumFromInt(90), .{ .tab_snapshot = ClientHarness.bootstrap_location });
    const version_before = client.model.version();
    const frames_before = preparedFrames(&harness);
    const reconciled = try core.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(90),
        .location = ClientHarness.bootstrap_location,
        .panes = &.{.{ .pane_id = ClientHarness.bootstrap_pane, .lifecycle = .running }},
    });

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(reconciled));

    try std.testing.expect(client.model.panes.find(retired) == null);
    try std.testing.expect(!client.graphics.hasPaneGraphics(retired));
    try std.testing.expect(!data.copy_mode.isActive(&client.model));
    try std.testing.expectEqual(@as(?core.PaneId, ClientHarness.bootstrap_pane), fixtures.reportedPaneId(client));
    try std.testing.expect(client.model.request_lifecycle.tracker.take(@enumFromInt(91)).? == .ignored);
    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(frames_before, preparedFrames(&harness));

    try harness.present();

    try std.testing.expectEqual(frames_before + 1, preparedFrames(&harness));
}

test "an unexpected tab snapshot is rejected instead of adopted" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();

    const client = harness.client;
    const version_before = client.model.version();
    const request_count_before = client.model.request_lifecycle.tracker.count;
    const frames_before = preparedFrames(&harness);
    var payload: [256]u8 = undefined;
    const snapshot = try core.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(99),
        .location = ClientHarness.bootstrap_location,
        .panes = &.{},
    });
    try std.testing.expectError(
        error.UnexpectedTabSnapshot,
        client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(snapshot)),
    );

    try std.testing.expectEqual(request_count_before, client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(frames_before, preparedFrames(&harness));
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "tab snapshot consumes an incompatible continuation before rejection" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: core.RequestId = @enumFromInt(4);
    try client.model.request_lifecycle.tracker.add(request_id, .notification);
    var payload: [256]u8 = undefined;
    const encoded = try core.encodeTabSnapshot(&payload, .{
        .request_id = request_id,
        .location = ClientHarness.bootstrap_location,
        .panes = &.{},
    });
    const snapshot = (try core.decodeServer(encoded)).tab_snapshot;

    try std.testing.expectError(error.UnexpectedTabSnapshot, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .tab_snapshot = snapshot,
        },
    ));
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabSnapshot, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .tab_snapshot = snapshot,
        },
    ));
    try std.testing.expectEqualDeep(data.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "tab snapshot consumes a mismatched location before rejection" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: core.RequestId = @enumFromInt(4);
    try client.model.request_lifecycle.tracker.add(request_id, .{ .tab_snapshot = ClientHarness.bootstrap_location });
    var payload: [256]u8 = undefined;
    const encoded = try core.encodeTabSnapshot(&payload, .{
        .request_id = request_id,
        .location = .{
            .workspace = ClientHarness.bootstrap_location.workspace,
            .tab_id = @enumFromInt(2),
        },
        .panes = &.{},
    });

    try std.testing.expectError(
        error.UnexpectedTabSnapshot,
        client_module.runtime_messages.handleServerMessage(
            client,
            .{
                .tab_snapshot = (try core.decodeServer(encoded)).tab_snapshot,
            },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(data.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "tab snapshot consumes correlation before a model rejection" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: core.RequestId = @enumFromInt(4);
    try client.model.request_lifecycle.tracker.add(request_id, .{ .tab_snapshot = ClientHarness.bootstrap_location });
    var payload: [256]u8 = undefined;
    const encoded = try core.encodeTabSnapshot(&payload, .{
        .request_id = request_id,
        .location = ClientHarness.bootstrap_location,
        .panes = &.{},
    });

    try std.testing.expectError(
        error.UnexpectedTab,
        client_module.runtime_messages.handleServerMessage(
            client,
            .{
                .tab_snapshot = (try core.decodeServer(encoded)).tab_snapshot,
            },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(data.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "an unexpected workspace snapshot is rejected without effects" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const request_count_before = client.model.request_lifecycle.tracker.count;
    const frames_before = preparedFrames(&harness);
    var payload: [512]u8 = undefined;
    const encoded = try core.encodeWorkspaceSnapshot(&payload, .{
        .request_id = @enumFromInt(99),
        .workspace = ClientHarness.bootstrap_location.workspace,
        .name = "main",
        .tabs = &.{.{
            .tab_id = ClientHarness.bootstrap_location.tab_id,
            .position = 0,
            .pane_count = 1,
            .label = "main",
        }},
    });

    try std.testing.expectError(
        error.UnexpectedWorkspaceSnapshot,
        client_module.runtime_messages.handleServerMessage(
            client,
            .{
                .workspace_snapshot = (try core.decodeServer(encoded)).workspace_snapshot,
            },
        ),
    );

    try std.testing.expectEqual(request_count_before, client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(frames_before, preparedFrames(&harness));
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "workspace snapshot consumes an incompatible continuation before rejection" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: core.RequestId = @enumFromInt(4);
    try client.model.request_lifecycle.tracker.add(request_id, .notification);
    var payload: [512]u8 = undefined;
    const encoded = try core.encodeWorkspaceSnapshot(&payload, .{
        .request_id = request_id,
        .workspace = ClientHarness.bootstrap_location.workspace,
        .name = "main",
        .tabs = &.{.{
            .tab_id = ClientHarness.bootstrap_location.tab_id,
            .position = 0,
            .pane_count = 1,
            .label = "main",
        }},
    });
    const snapshot = (try core.decodeServer(encoded)).workspace_snapshot;

    try std.testing.expectError(error.UnexpectedWorkspaceSnapshot, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .workspace_snapshot = snapshot,
        },
    ));
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedWorkspaceSnapshot, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .workspace_snapshot = snapshot,
        },
    ));
    try std.testing.expectEqualDeep(data.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "workspace snapshot consumes a mismatched workspace before rejection" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: core.RequestId = @enumFromInt(4);
    try client.model.request_lifecycle.tracker.add(request_id, .{
        .workspace_snapshot = ClientHarness.bootstrap_location.workspace,
    });
    var payload: [512]u8 = undefined;
    const encoded = try core.encodeWorkspaceSnapshot(&payload, .{
        .request_id = request_id,
        .workspace = .{ .workspace = @enumFromInt(2) },
        .name = "other",
        .tabs = &.{.{
            .tab_id = @enumFromInt(2),
            .position = 0,
            .pane_count = 1,
            .label = "main",
        }},
    });

    try std.testing.expectError(
        error.UnexpectedWorkspaceSnapshot,
        client_module.runtime_messages.handleServerMessage(
            client,
            .{
                .workspace_snapshot = (try core.decodeServer(encoded)).workspace_snapshot,
            },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(data.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "workspace snapshot consumes correlation before a model rejection" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: core.RequestId = @enumFromInt(4);
    try client.model.request_lifecycle.tracker.add(request_id, .{
        .workspace_snapshot = ClientHarness.bootstrap_location.workspace,
    });
    var payload: [512]u8 = undefined;
    const encoded = try core.encodeWorkspaceSnapshot(&payload, .{
        .request_id = request_id,
        .workspace = ClientHarness.bootstrap_location.workspace,
        .name = "main",
        .tabs = &.{.{
            .tab_id = ClientHarness.bootstrap_location.tab_id,
            .position = 0,
            .pane_count = 1,
            .label = "main",
        }},
    });

    try std.testing.expectError(
        error.UnexpectedWorkspace,
        client_module.runtime_messages.handleServerMessage(
            client,
            .{
                .workspace_snapshot = (try core.decodeServer(encoded)).workspace_snapshot,
            },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(data.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "workspace snapshots commit semantic revisions before presentation" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const frames_before = preparedFrames(&harness);

    var payload: [512]u8 = undefined;
    const snapshot = try core.encodeWorkspaceSnapshot(&payload, .{
        .request_id = @enumFromInt(2),
        .workspace = ClientHarness.bootstrap_location.workspace,
        .name = "main",
        .tabs = &.{
            .{ .tab_id = @enumFromInt(1), .position = 0, .pane_count = 1, .label = "main" },
            .{ .tab_id = @enumFromInt(2), .position = 1, .pane_count = 1, .label = "second" },
        },
    });
    _ = try client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .workspace_snapshot = (try core.decodeServer(snapshot)).workspace_snapshot,
        },
    );

    try std.testing.expectEqual(@as(usize, 2), client.model.tabs.count);
    try std.testing.expect(client.model.tabs.find(@enumFromInt(2)) != null);
    try std.testing.expectEqualDeep(ClientHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqual(version_before.workspace + 1, client.model.version().workspace);
    try std.testing.expectEqual(version_before.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(frames_before, preparedFrames(&harness));

    try harness.present();

    try std.testing.expectEqual(frames_before + 1, preparedFrames(&harness));
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);

    const version_before_noop = client.model.version();
    const frames_before_noop = preparedFrames(&harness);
    try client.model.request_lifecycle.tracker.add(@enumFromInt(4), .{
        .workspace_snapshot = ClientHarness.bootstrap_location.workspace,
    });
    const unchanged = try core.encodeWorkspaceSnapshot(&payload, .{
        .request_id = @enumFromInt(4),
        .workspace = ClientHarness.bootstrap_location.workspace,
        .name = "main",
        .tabs = &.{
            .{ .tab_id = @enumFromInt(1), .position = 0, .pane_count = 1, .label = "main" },
            .{ .tab_id = @enumFromInt(2), .position = 1, .pane_count = 1, .label = "second" },
        },
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(unchanged));
    try harness.present();

    try std.testing.expectEqualDeep(version_before_noop, client.model.version());
    try std.testing.expectEqual(frames_before_noop, preparedFrames(&harness));
}

test "workspace reconciliation retires removed state and restores the new active tab" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second = try harness.addInactiveTab(@enumFromInt(2), @enumFromInt(20));
    try client.model.request_lifecycle.tracker.add(@enumFromInt(90), .{ .rename_tab = ClientHarness.bootstrap_location });
    var images: PaneImages = .{
        .retained = &harness.graphics,
    };
    client.graphics = images.port();
    try images.add(ClientHarness.bootstrap_pane);
    try std.testing.expect(client.graphics.hasPaneGraphics(ClientHarness.bootstrap_pane));
    const frames_before = preparedFrames(&harness);

    var payload: [512]u8 = undefined;
    const snapshot = try core.encodeWorkspaceSnapshot(&payload, .{
        .request_id = @enumFromInt(2),
        .workspace = ClientHarness.bootstrap_location.workspace,
        .name = "main",
        .tabs = &.{
            .{ .tab_id = second.tab_id, .position = 0, .pane_count = 1, .label = "second" },
        },
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(snapshot));

    try std.testing.expectEqualDeep(second, client.model.activeTabLocation().?);
    try std.testing.expect(!client.graphics.hasPaneGraphics(ClientHarness.bootstrap_pane));
    try std.testing.expect(client.graphics.paneVisible(@enumFromInt(20)));
    try std.testing.expectEqual(@as(?core.PaneId, @enumFromInt(20)), fixtures.reportedPaneId(client));
    const version_before_late_snapshot = client.model.version();
    const frames_before_late_snapshot = preparedFrames(&harness);
    const outbox_len_before_late_snapshot = client.model.to_runtime.len;
    const request_count_before_late_snapshot = client.model.request_lifecycle.tracker.count;
    const late_snapshot = try core.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(3),
        .location = ClientHarness.bootstrap_location,
        .panes = &.{},
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try client_module.runtime_messages.handleServerMessage(
            client,
            .{
                .tab_snapshot = (try core.decodeServer(late_snapshot)).tab_snapshot,
            },
        ),
    );

    try std.testing.expectEqual(request_count_before_late_snapshot - 1, client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before_late_snapshot, client.model.version());
    try std.testing.expectEqual(frames_before_late_snapshot, preparedFrames(&harness));
    try std.testing.expectEqual(outbox_len_before_late_snapshot, client.model.to_runtime.len);
    try std.testing.expect(client.model.request_lifecycle.tracker.take(@enumFromInt(90)).? == .ignored);
    try std.testing.expectEqual(frames_before, preparedFrames(&harness));
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const requested = try harness.nextClientMessage(&buffer);
    try std.testing.expect(requested == .request_tab_snapshot);
    try std.testing.expectEqualDeep(second, requested.request_tab_snapshot.location);
}

test "resync required requests one workspace snapshot and coalesces repeats" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.model.workspace = ClientHarness.bootstrap_location.workspace;
    // The first frame of the unopened client, so only the resync's own
    // frames are counted below.
    try harness.present();
    const version_before = client.model.version();
    const frames_before = preparedFrames(&harness);
    const required: core.ResyncRequired = .{
        .workspace = ClientHarness.bootstrap_location.workspace,
        .workspace_closed = false,
    };

    try std.testing.expectEqual(
        @as(?u8, null),
        try client_module.runtime_messages.handleServerMessage(
            client,
            .{
                .resync_required = required,
            },
        ),
    );
    try std.testing.expectEqual(
        @as(?u8, null),
        try client_module.runtime_messages.handleServerMessage(
            client,
            .{
                .resync_required = required,
            },
        ),
    );
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const first = try harness.nextClientMessage(&buffer);
    try std.testing.expect(first == .request_workspace_snapshot);
    try std.testing.expect(client.model.request_lifecycle.tracker.has(.workspace_snapshot));
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(frames_before, preparedFrames(&harness));
}

test "resync rejects a workspace other than the current projection" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.model.workspace = ClientHarness.bootstrap_location.workspace;
    const next_request_id = client.model.request_lifecycle.next_request_id;

    try std.testing.expectError(
        error.UnexpectedResync,
        client_module.runtime_messages.handleServerMessage(
            client,
            .{
                .resync_required = .{
                    .workspace = .{
                        .workspace = @enumFromInt(9),
                    },
                    .workspace_closed = false,
                },
            },
        ),
    );
    try std.testing.expectEqual(next_request_id, client.model.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "resync keeps a closed bookmark forgotten when predecessor handoff is blocked" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.model.navigation_history.remember(.{
        .location = ClientHarness.bootstrap_location,
        .pane_id = ClientHarness.bootstrap_pane,
    });
    try client.model.request_lifecycle.tracker.add(@enumFromInt(7), .notification);
    const version_before = client.model.version();

    try std.testing.expectError(
        error.WorkspaceSwitchWhileRequestPending,
        client_module.runtime_messages.handleServerMessage(
            client,
            .{
                .resync_required = .{
                    .workspace = ClientHarness.bootstrap_location.workspace,
                    .workspace_closed = true,
                    .previous_workspace = @enumFromInt(2),
                },
            },
        ),
    );
    try std.testing.expect(
        client.model.navigation_history.find(ClientHarness.bootstrap_location.workspace) == null,
    );
    try std.testing.expectEqual(@as(usize, 1), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
}

test "resync outbox failure releases its snapshot correlation so a later notice can retry" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    try client.model.to_runtime.push(
        .{
            .detach_pane = .{
                .pane_id = ClientHarness.bootstrap_pane,
            },
        },
    );
    while (client.model.to_runtime.hasCapacity()) {
        try client.model.to_runtime.push(.{ .detach_pane = .{ .pane_id = ClientHarness.bootstrap_pane } });
    }
    const version = client.model.version();
    const notice: core.ResyncRequired = .{ .workspace = ClientHarness.bootstrap_location.workspace, .workspace_closed = false };

    try std.testing.expectError(error.ClientOutboxFull, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .resync_required = notice,
        },
    ));

    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version, client.model.version());
    try harness.settle();
    var outgoing: [256]u8 = undefined;
    for (0..data.outbox_support.capacity) |_| {
        try std.testing.expect((try harness.nextClientMessage(&outgoing)) == .detach_pane);
    }

    try std.testing.expectEqual(@as(?u8, null), try client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .resync_required = notice,
        },
    ));
    try std.testing.expectEqual(@as(?u8, null), try client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .resync_required = notice,
        },
    ));
    try std.testing.expectEqual(@as(usize, 1), client.model.request_lifecycle.tracker.count);
    try harness.settle();
    const recovery = try harness.nextClientMessage(&outgoing);
    try std.testing.expect(recovery == .request_workspace_snapshot);
    try std.testing.expectEqualDeep(notice.workspace, recovery.request_workspace_snapshot.workspace);
}

// Frames the harness has begun presenting: the presentation lifecycle
// issues one token per prepared frame.
fn preparedFrames(harness: *const ClientHarness) u64 {
    return harness.client.presentation.next_token;
}

// Presses one key through the keymap, as a window delivers it.
fn pressKey(harness: *ClientHarness, key: keyinput.Key) !void {
    const app = harness.client;
    var router = try client_module.key_router.build(app.routerConfig());
    const decision = router.routeEvent(
        .{
            .key = key,
            .raw = "",
            .now_ns = 0,
        },
        .{
            .captures_keys = data.key_routing.captures(client_module.key_routing.keyRoutingAuthority(app)),
            .repeat_policy = null,
        },
    );

    switch (decision) {
        .forward => |value| _ = try client_module.key_routing.routeKeyInput(app, .{ .key = value.key }),
        .action => |request| _ = try client_module.actions.executeAction(app, request.value, .binding),
        .replay, .pending, .discard => return error.UnexpectedKeyDecision,
    }
}

// Types each character of `text` as its own key press.
fn typeText(harness: *ClientHarness, text: []const u8) !void {
    for (0..text.len) |index| {
        try pressKey(harness, .plain(.{ .char = keyinput.Char.init(text[index..][0..1]) }));
    }
}

/// The harness's graphics stand-in keeps no images. This one remembers which
/// panes hold one until the client clears them, and leaves visibility to the
/// harness's stand-in.
const PaneImages = struct {
    const capacity = 4;

    retained: *RetainedGraphics,
    panes: [capacity]core.PaneId = undefined,
    count: usize = 0,

    fn add(self: *PaneImages, pane_id: core.PaneId) !void {
        if (self.count == capacity) {
            return error.TooManyPaneImages;
        }

        self.panes[self.count] = pane_id;
        self.count += 1;
    }

    fn port(self: *PaneImages) client_module.GraphicsRetention {
        return .{
            .context = self,
            .apply_fn = apply,
            .clear_pane_fn = clearPane,
            .set_pane_visible_fn = setVisible,
            .pane_visible_fn = visible,
            .has_pane_graphics_fn = hasGraphics,
            .ingress_version_fn = ingress,
            .peek_credit_fn = peekCredit,
            .consume_credit_fn = consumeCredit,
        };
    }

    fn from(context: *anyopaque) *PaneImages {
        return @ptrCast(@alignCast(context));
    }

    fn apply(context: *anyopaque, command: data.PaneGraphicsCommand) !void {
        try from(context).retained.port().apply(command);
    }

    fn clearPane(context: *anyopaque, pane_id: core.PaneId) void {
        const self = from(context);
        for (self.panes[0..self.count], 0..) |pane, index| {
            if (pane == pane_id) {
                self.panes[index] = self.panes[self.count - 1];
                self.count -= 1;
                return;
            }
        }
    }

    fn setVisible(context: *anyopaque, pane_id: core.PaneId, value: bool) !void {
        try from(context).retained.setPaneVisible(pane_id, value);
    }

    fn visible(context: *anyopaque, pane_id: core.PaneId) bool {
        return from(context).retained.port().paneVisible(pane_id);
    }

    fn hasGraphics(context: *anyopaque, pane_id: core.PaneId) bool {
        const self = from(context);
        for (self.panes[0..self.count]) |pane| {
            if (pane == pane_id) {
                return true;
            }
        }

        return false;
    }

    fn ingress(context: *anyopaque) u64 {
        return from(context).retained.port().ingressVersion();
    }

    fn peekCredit(_: *anyopaque) ?client_module.GraphicsCredit {
        return null;
    }

    fn consumeCredit(_: *anyopaque, _: client_module.GraphicsCredit) void {}
};
