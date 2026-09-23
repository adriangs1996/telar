//! Client integration tests for synchronization.

const core = @import("telar-core");
const client_module = @import("telar-client");
const data = @import("model");
const TerminalClient = @import("../TerminalClient.zig");
const TestHarness = @import("TestHarness.zig");
const std = @import("std");
const host_inputs = @import("../controllers/input/host_inputs.zig");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const support = @import("support.zig");

test "pane opening rejects an unknown request without client effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const version_before = client.model.version();
    const pending_updates_before = TerminalClient.of(client).presenter.pending_updates;

    try std.testing.expectError(error.UnexpectedRequest, client.handleServerMessage(
        .{
            .pane_opened = .{
                .request_id = @enumFromInt(99),
                .pane_id = TestHarness.bootstrap_pane,
                .location = TestHarness.bootstrap_location,
                .created = true,
            },
        },
    ));

    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, TerminalClient.of(client).presenter.pending_updates);
}

test "pane opening consumes an incompatible continuation before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: core.RequestId = @enumFromInt(4);
    const opened: core.PaneOpened = .{
        .request_id = request_id,
        .pane_id = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .created = true,
    };
    const version_before = client.model.version();
    const pending_updates_before = TerminalClient.of(client).presenter.pending_updates;
    try client.request_lifecycle.tracker.add(request_id, .notification);

    try std.testing.expectError(error.UnexpectedRequest, client.handleServerMessage(
        .{
            .pane_opened = opened,
        },
    ));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedRequest, client.handleServerMessage(
        .{
            .pane_opened = opened,
        },
    ));
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, TerminalClient.of(client).presenter.pending_updates);
}

test "pane opening consumes an ignored continuation without client effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: core.RequestId = @enumFromInt(4);
    const version_before = client.model.version();
    const pending_updates_before = TerminalClient.of(client).presenter.pending_updates;
    try client.request_lifecycle.tracker.add(request_id, .ignored);

    try std.testing.expectEqual(@as(?u8, null), try client.handleServerMessage(
        .{
            .pane_opened = .{
                .request_id = request_id,
                .pane_id = TestHarness.bootstrap_pane,
                .location = TestHarness.bootstrap_location,
                .created = false,
            },
        },
    ));

    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, TerminalClient.of(client).presenter.pending_updates);
}

test "new tab request captures launch source geometry and continuation without mutation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    harness.client.options.arguments = &.{"/bin/sh"};
    const version_before_request = harness.client.model.version();
    const pending_updates_before_request = TerminalClient.of(harness.client).presenter.pending_updates;

    _ = try harness.client.executeAction(.new_tab, .effect);
    try harness.settle();

    var buffer: [512]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .create_tab);
    const created = message.create_tab;
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location.workspace, created.workspace);
    try std.testing.expectEqualStrings("", created.label);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, created.launch.cwd_source.?);
    try std.testing.expectEqual(core.TerminalSize{
        .cols = TerminalClient.of(harness.client).view.workbench().w,
        .rows = TerminalClient.of(harness.client).view.workbench().h,
    }, created.size);
    try std.testing.expectEqualDeep(version_before_request, harness.client.model.version());
    try std.testing.expectEqual(pending_updates_before_request, TerminalClient.of(harness.client).presenter.pending_updates);

    const continuation = harness.client.request_lifecycle.tracker.take(created.request_id).?;
    try std.testing.expect(continuation == .create_tab);
    try std.testing.expectEqualDeep(created.workspace, continuation.create_tab.workspace);
    try std.testing.expectEqual(created.size, continuation.create_tab.size);
}

test "new pane inherits cwd from the focused runtime pane" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    harness.client.options.arguments = &.{"/bin/sh"};

    _ = try harness.client.executeAction(
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
    try std.testing.expectEqual(TestHarness.bootstrap_pane, created.launch.cwd_source.?);
}

test "new workspace inherits cwd from the focused runtime pane" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    harness.client.options.arguments = &.{"/bin/sh"};
    harness.client.request_lifecycle.tracker = .{};

    _ = try harness.client.executeAction(.new_workspace, .effect);
    try host_inputs.forward(harness.client, "agents\r");
    try harness.settle();

    var buffer: [512]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .create_workspace);
    const created = message.create_workspace;
    try std.testing.expectEqualStrings("agents", created.name);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, created.launch.cwd_source.?);
}

test "workspace handoff opens the pane remembered for that workspace" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};

    const destination: core.WorkspaceLocation = .{ .workspace = @enumFromInt(2) };
    const restored_pane: core.PaneId = @enumFromInt(77);
    client.navigation_history.remember(.{
        .location = .{ .workspace = destination, .tab_id = @enumFromInt(8) },
        .pane_id = restored_pane,
    });
    const version_before_departure = client.model.version();
    const pending_updates_before_departure = TerminalClient.of(client).presenter.pending_updates;
    _ = try client.requestWorkspace(@enumFromInt(2));

    try std.testing.expect(client.model.workspaceLocation() == null);
    try std.testing.expectEqual(@as(usize, 0), client.model.tabs.count);
    try std.testing.expectEqual(version_before_departure.workspace + 1, client.model.version().workspace);
    try std.testing.expectEqual(version_before_departure.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_departure.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(version_before_departure.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_departure, TerminalClient.of(client).presenter.pending_updates);
    try std.testing.expect(client.model.reportedPaneFocus() == null);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_departure + 1, TerminalClient.of(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try harness.settle();
    try std.testing.expectEqualDeep(client.model.version(), TerminalClient.of(client).presenter.presentation_state.prepared.model);
    try std.testing.expectEqual(@as(usize, 0), TerminalClient.of(client).presenter.pending_updates);
    for (TerminalClient.of(client).presenter.screen.front.cells) |cell| {
        try std.testing.expectEqualStrings(" ", cell.text());
        try std.testing.expectEqual(@as(u8, 1), cell.width);
    }
    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(@as(usize, 0), TerminalClient.of(client).presenter.pending_updates);

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
    const current = client.navigation_history.find(TestHarness.bootstrap_location.workspace).?;
    try std.testing.expectEqual(TestHarness.bootstrap_pane, current.pane_id);
    try std.testing.expect(current.tab_layout != null);

    var payload: [128]u8 = undefined;
    const failed = try core.encodeRequestFailed(&payload, .{
        .request_id = request_id,
        .code = .pane_not_found,
        .message = "remembered pane closed",
    });
    const version_before_recovery = client.model.version();
    const pending_updates_before_recovery = TerminalClient.of(client).presenter.pending_updates;
    _ = try client.handleServerMessage(try core.decodeServer(failed));

    try std.testing.expectEqualDeep(version_before_recovery, client.model.version());
    try std.testing.expectEqual(pending_updates_before_recovery, TerminalClient.of(client).presenter.pending_updates);
    try harness.settle();
    const fallback = (try harness.nextClientMessage(&buffer)).open_pane;
    try std.testing.expectEqualDeep(
        core.PaneTarget{ .workspace = @enumFromInt(2) },
        fallback.target,
    );
    const retry = client.request_lifecycle.tracker.take(fallback.request_id).?;
    try std.testing.expect(retry == .initial_open);
    try std.testing.expect(retry.initial_open.fallback_workspace == null);
    try std.testing.expect(client.navigation_history.find(destination) == null);
}

test "workspace handoff capacity failure preserves the source model" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    while (client.runtime_transport.outbox.len < data.outbox_support.capacity - 1) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const version_before = client.model.version();
    const focus_before = client.model.reportedPaneFocus();
    const next_request_id = client.request_lifecycle.next_request_id;

    try std.testing.expectError(
        error.ClientOutboxFull,
        client.requestWorkspace(@enumFromInt(2)),
    );

    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expect(client.model.panes.find(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqualDeep(focus_before, client.model.reportedPaneFocus());
    try std.testing.expect(client.navigation_history.find(TestHarness.bootstrap_location.workspace) == null);
    try std.testing.expectEqual(next_request_id, client.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqual(data.outbox_support.capacity - 1, @as(usize, client.runtime_transport.outbox.len));
}

test "workspace handoff request exhaustion preserves the source model" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    client.request_lifecycle.next_request_id = std.math.maxInt(u64) - 1;
    const version_before = client.model.version();
    const focus_before = client.model.reportedPaneFocus();
    const outbox_len = client.runtime_transport.outbox.len;

    try std.testing.expectError(
        error.RequestIdExhausted,
        client.requestWorkspace(@enumFromInt(2)),
    );

    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expect(client.model.panes.find(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqualDeep(focus_before, client.model.reportedPaneFocus());
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, client.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqual(outbox_len, client.runtime_transport.outbox.len);
}

test "workspace handoff reserves its focus-out message" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    client.model.panes.find(TestHarness.bootstrap_pane).?.input_modes.focus_events = true;
    try client.synchronizeActivePane();
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const focus_in = try harness.nextClientMessage(&buffer);
    try std.testing.expect(focus_in == .pane_input);
    try std.testing.expectEqualStrings("\x1b[I", focus_in.pane_input.bytes);
    while (client.runtime_transport.outbox.len < data.outbox_support.capacity - 2) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const version = client.model.version();
    const reported = client.model.reportedPaneFocus();

    try std.testing.expectError(
        error.ClientOutboxFull,
        client.requestWorkspace(@enumFromInt(2)),
    );

    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqualDeep(reported, client.model.reportedPaneFocus());
    try std.testing.expect(client.model.panes.find(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
}

test "workspace handoff reserves its captured paste closing marker" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    client.model.panes.find(TestHarness.bootstrap_pane).?.input_modes.bracketed_paste = true;
    _ = try client_module.operations.paste_routing.start(client);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const opening = try harness.nextClientMessage(&buffer);
    try std.testing.expect(opening == .pane_input);
    try std.testing.expectEqualStrings("\x1b[200~", opening.pane_input.bytes);
    while (client.runtime_transport.outbox.len < data.outbox_support.capacity - 2) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const version = client.model.version();

    try std.testing.expectError(
        error.ClientOutboxFull,
        client.requestWorkspace(@enumFromInt(2)),
    );

    try std.testing.expect(client.model.panePasteActive());
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expect(client.model.panes.find(TestHarness.bootstrap_pane).?.attached);
}

test "clicking a sidebar agent hands off directly to its pane" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};

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
    client.navigation_history.remember(.{
        .location = agent.location,
        .pane_id = bottom_right_pane,
        .tab_layout = saved_layout,
    });
    _ = try client.model.reconcileAgentSnapshot(.{
        .revision = 1,
        .agents = &.{agent},
    });
    const model = client.model.tabs.active;
    _ = try TerminalClient.of(client).view.render(&TerminalClient.of(client).presenter.screen, .{
        .model = &client.model,
        .tab = model,
        .agents = client.model.agentSnapshot(),
        .force = true,
    });
    try host_inputs.mouse(client, .{ .x = 4, .y = 4, .kind = .press });
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
    const pending_updates_before_arrival = TerminalClient.of(client).presenter.pending_updates;
    _ = try client.handleServerMessage(try core.decodeServer(opened));

    try std.testing.expectEqual(version_before_arrival.workspace + 1, client.model.version().workspace);
    try std.testing.expectEqual(version_before_arrival.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_arrival.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(version_before_arrival.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_arrival, TerminalClient.of(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_arrival + 1, TerminalClient.of(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try harness.settle();
    try std.testing.expectEqualDeep(client.model.version(), TerminalClient.of(client).presenter.presentation_state.prepared.model);
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
    _ = try client.handleServerMessage(try core.decodeServer(snapshot));

    const restored = client.model.tabs.active;
    try std.testing.expectEqual(agent_pane, client.model.tabs.layout[restored].focused().?);
    try std.testing.expect(client.model.tabs.layout[restored].isFullscreen());
    try std.testing.expectEqual(@as(u16, 2), client.model.tabs.layout[restored].displayIndex(agent_pane).?);
    var expected_geometry: data.LayoutSnapshot = .{};
    var actual_geometry: data.LayoutSnapshot = .{};
    var actual_tiled = client.model.tabs.layout[restored];
    try std.testing.expect(saved_layout.toggleFullscreen());
    try std.testing.expect(actual_tiled.toggleFullscreen());
    saved_layout.snapshot(TerminalClient.of(client).view.workbench(), &expected_geometry);
    actual_tiled.snapshot(TerminalClient.of(client).view.workbench(), &actual_geometry);
    for ([_]core.PaneId{ left_pane, agent_pane, bottom_right_pane }) |pane_id|
        try std.testing.expectEqual(
            expected_geometry.find(pane_id).?.outer,
            actual_geometry.find(pane_id).?.outer,
        );
}

test "sidebar workspace round trip restores fullscreen in a previously inactive tab" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const first = TestHarness.bootstrap_pane;
    const clicked: core.PaneId = @enumFromInt(21);
    const area = TerminalClient.of(client).view.workbench();
    _ = try client.model.reconcileTab(.{ .location = TestHarness.bootstrap_location, .panes = &.{first} }, area);
    const fullscreen_tab = client.model.tabs.active;
    try data.pane_split.split(&client.model, fullscreen_tab, .{ .existing_pane = first, .new_pane = clicked, .location = TestHarness.bootstrap_location, .axis = .vertical, .area = area });
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
            .location = TestHarness.bootstrap_location,
            .pane_index = 2,
            .provider = .codex,
            .status = .working,
        },
    };
    _ = try client.model.reconcileAgentSnapshot(.{ .revision = 1, .agents = &destinations });

    for (destinations, 0..) |agent, turn| {
        try std.testing.expectEqual(.handoff_requested, try client.navigateAgent(agent.key));
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
        _ = try client.handleServerMessage(try core.decodeServer(opened));
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
        _ = try client.handleServerMessage(try core.decodeServer(workspace_snapshot));
        const panes = [_]core.PaneDescriptor{
            .{ .pane_id = agent.key.pane_id, .lifecycle = .running },
            .{ .pane_id = first, .lifecycle = .running },
        };
        const tab_snapshot = try core.encodeTabSnapshot(&buffer, .{
            .request_id = tab_request,
            .location = agent.location,
            .panes = panes[0..if (turn == 0) @as(usize, 1) else 2],
        });
        _ = try client.handleServerMessage(try core.decodeServer(tab_snapshot));
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
    var harness: TestHarness = undefined;
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
    _ = try client.model.reconcileAgentSnapshot(.{
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
    const pending_updates = TerminalClient.of(client).presenter.pending_updates;

    try std.testing.expectEqual(
        .focused,
        try client.navigateAgent(key),
    );

    try std.testing.expectEqualDeep(location, client.model.activeTabLocation().?);
    try std.testing.expectEqual(agent_pane, client.model.tabs.layout[client.model.tabs.active].focused().?);
    try std.testing.expectEqual(version.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(version.panes, client.model.version().panes);
    try std.testing.expectEqual(pending_updates, TerminalClient.of(client).presenter.pending_updates);

    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, detached.detach_pane.pane_id);
    const snapshot = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(snapshot == .request_tab_snapshot);
    try std.testing.expectEqualDeep(location, snapshot.request_tab_snapshot.location);
}

test "local sidebar agent navigation keeps fullscreen when targeting a different pane" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    try harness.allowTabSelection();
    const client = harness.client;
    const first: core.PaneId = @enumFromInt(20);
    const clicked: core.PaneId = @enumFromInt(21);
    const location = try harness.addInactiveTab(@enumFromInt(2), first);
    const tab = client.model.tabs.find(location.tab_id).?;
    const area = TerminalClient.of(client).view.workbench();
    try data.pane_split.split(&client.model, tab, .{ .existing_pane = first, .new_pane = clicked, .location = location, .axis = .vertical, .area = area });
    try std.testing.expect(client.model.tabs.layout[tab].focusPane(first));
    try std.testing.expect(client.model.tabs.layout[tab].toggleFullscreen());
    const key: data.AgentKey = .{ .pane_id = clicked, .pane_generation = 1 };
    _ = try client.model.reconcileAgentSnapshot(.{
        .revision = 1,
        .agents = &.{.{ .key = key, .location = location, .pane_index = 2, .provider = .codex, .status = .working }},
    });

    try std.testing.expectEqual(.focused, try client.navigateAgent(key));
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
    _ = try client.handleServerMessage(try core.decodeServer(payload));
    try std.testing.expect(client.model.tabs.layout[tab].isFullscreen());
    try std.testing.expectEqual(clicked, client.model.tabs.layout[tab].focused().?);
    try std.testing.expect(data.tab_layout.contentSize(&client.model, tab, first, area) == null);
    try std.testing.expectEqual(core.TerminalSize{ .cols = area.w - 2, .rows = area.h - 2 }, data.tab_layout.contentSize(&client.model, tab, clicked, area).?);
}

test "tab snapshots commit pane revisions before attaching and presenting" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const pending_updates_before = TerminalClient.of(client).presenter.pending_updates;

    const discovered: core.PaneId = @enumFromInt(11);
    var payload: [256]u8 = undefined;
    const snapshot = try core.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(3),
        .location = TestHarness.bootstrap_location,
        .panes = &.{
            .{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running },
            .{ .pane_id = discovered, .lifecycle = .running },
        },
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try client.handleServerMessage(
            .{
                .tab_snapshot = (try core.decodeServer(snapshot)).tab_snapshot,
            },
        ),
    );

    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(version_before.workspace, client.model.version().workspace);
    try std.testing.expectEqual(version_before.tabs, client.model.version().tabs);
    try std.testing.expectEqual(version_before.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before, TerminalClient.of(client).presenter.pending_updates);
    const committed_version = client.model.version();
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{ .tab_snapshot = TestHarness.bootstrap_location });
    const repeated = try core.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(90),
        .location = TestHarness.bootstrap_location,
        .panes = &.{
            .{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running },
            .{ .pane_id = discovered, .lifecycle = .running },
        },
    });
    _ = try client.handleServerMessage(try core.decodeServer(repeated));

    try std.testing.expectEqualDeep(committed_version, client.model.version());
    try std.testing.expect(client.request_lifecycle.tracker.hasPane(.attachment, discovered));
    try std.testing.expectEqual(@as(usize, 2), client.request_lifecycle.tracker.count);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before + 1, TerminalClient.of(client).presenter.pending_updates);
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
    try std.testing.expectEqualDeep(client.model.version(), TerminalClient.of(client).presenter.presentation_state.prepared.model);
}

test "an identical tab snapshot repairs resources without scheduling a frame" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    var payload: [256]u8 = undefined;
    const initial = try core.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(3),
        .location = TestHarness.bootstrap_location,
        .panes = &.{.{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running }},
    });
    _ = try client.handleServerMessage(try core.decodeServer(initial));
    try presentation_lifecycle.observe(client);
    try harness.settle();
    try harness.settleModelPresentation();
    const committed_version = client.model.version();
    const pending_updates_before = TerminalClient.of(client).presenter.pending_updates;
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{ .tab_snapshot = TestHarness.bootstrap_location });
    const unchanged = try core.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(90),
        .location = TestHarness.bootstrap_location,
        .panes = &.{.{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running }},
    });

    _ = try client.handleServerMessage(try core.decodeServer(unchanged));
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(committed_version, client.model.version());
    try std.testing.expectEqual(pending_updates_before, TerminalClient.of(client).presenter.pending_updates);
}

test "tab reconciliation retires removed pane resources and continuations" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    var payload: [256]u8 = undefined;
    const initial = try core.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(3),
        .location = TestHarness.bootstrap_location,
        .panes = &.{.{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running }},
    });
    _ = try client.handleServerMessage(try core.decodeServer(initial));
    try harness.settle();

    const retired: core.PaneId = @enumFromInt(11);
    const model = client.model.tabs.active;
    try data.pane_split.split(&client.model, model, .{ .existing_pane = TestHarness.bootstrap_pane, .new_pane = retired, .location = TestHarness.bootstrap_location, .axis = .horizontal, .area = TerminalClient.of(client).view.workbench() });
    try client.synchronizeActivePane();
    try std.testing.expect(client.model.enterCopyMode());
    try TerminalClient.of(client).graphics_store.applyImage(.{
        .pane_id = retired,
        .revision = 1,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        },
    });
    try client.request_lifecycle.tracker.add(@enumFromInt(91), .{ .close_pane = .{
        .pane_id = retired,
        .location = TestHarness.bootstrap_location,
    } });
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{ .tab_snapshot = TestHarness.bootstrap_location });
    const version_before = client.model.version();
    const pending_updates_before = TerminalClient.of(client).presenter.pending_updates;
    const reconciled = try core.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(90),
        .location = TestHarness.bootstrap_location,
        .panes = &.{.{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running }},
    });

    _ = try client.handleServerMessage(try core.decodeServer(reconciled));

    try std.testing.expect(client.model.panes.find(retired) == null);
    try std.testing.expect(!TerminalClient.of(client).graphics_store.hasPaneGraphics(retired));
    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expectEqual(@as(?core.PaneId, TestHarness.bootstrap_pane), support.reportedPaneId(client));
    try std.testing.expect(client.request_lifecycle.tracker.take(@enumFromInt(91)).? == .ignored);
    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before, TerminalClient.of(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before + 1, TerminalClient.of(client).presenter.pending_updates);
}

test "an unexpected tab snapshot is rejected instead of adopted" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();

    const client = harness.client;
    const version_before = client.model.version();
    const request_count_before = client.request_lifecycle.tracker.count;
    const pending_updates_before = TerminalClient.of(client).presenter.pending_updates;
    var payload: [256]u8 = undefined;
    const snapshot = try core.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(99),
        .location = TestHarness.bootstrap_location,
        .panes = &.{},
    });
    try std.testing.expectError(
        error.UnexpectedTabSnapshot,
        client.handleServerMessage(try core.decodeServer(snapshot)),
    );

    try std.testing.expectEqual(request_count_before, client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, TerminalClient.of(client).presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "tab snapshot consumes an incompatible continuation before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: core.RequestId = @enumFromInt(4);
    try client.request_lifecycle.tracker.add(request_id, .notification);
    var payload: [256]u8 = undefined;
    const encoded = try core.encodeTabSnapshot(&payload, .{
        .request_id = request_id,
        .location = TestHarness.bootstrap_location,
        .panes = &.{},
    });
    const snapshot = (try core.decodeServer(encoded)).tab_snapshot;

    try std.testing.expectError(error.UnexpectedTabSnapshot, client.handleServerMessage(
        .{
            .tab_snapshot = snapshot,
        },
    ));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabSnapshot, client.handleServerMessage(
        .{
            .tab_snapshot = snapshot,
        },
    ));
    try std.testing.expectEqualDeep(data.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "tab snapshot consumes a mismatched location before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: core.RequestId = @enumFromInt(4);
    try client.request_lifecycle.tracker.add(request_id, .{ .tab_snapshot = TestHarness.bootstrap_location });
    var payload: [256]u8 = undefined;
    const encoded = try core.encodeTabSnapshot(&payload, .{
        .request_id = request_id,
        .location = .{
            .workspace = TestHarness.bootstrap_location.workspace,
            .tab_id = @enumFromInt(2),
        },
        .panes = &.{},
    });

    try std.testing.expectError(
        error.UnexpectedTabSnapshot,
        client.handleServerMessage(
            .{
                .tab_snapshot = (try core.decodeServer(encoded)).tab_snapshot,
            },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(data.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "tab snapshot consumes correlation before a model rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: core.RequestId = @enumFromInt(4);
    try client.request_lifecycle.tracker.add(request_id, .{ .tab_snapshot = TestHarness.bootstrap_location });
    var payload: [256]u8 = undefined;
    const encoded = try core.encodeTabSnapshot(&payload, .{
        .request_id = request_id,
        .location = TestHarness.bootstrap_location,
        .panes = &.{},
    });

    try std.testing.expectError(
        error.UnexpectedTab,
        client.handleServerMessage(
            .{
                .tab_snapshot = (try core.decodeServer(encoded)).tab_snapshot,
            },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(data.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "an unexpected workspace snapshot is rejected without effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const request_count_before = client.request_lifecycle.tracker.count;
    const pending_updates_before = TerminalClient.of(client).presenter.pending_updates;
    var payload: [512]u8 = undefined;
    const encoded = try core.encodeWorkspaceSnapshot(&payload, .{
        .request_id = @enumFromInt(99),
        .workspace = TestHarness.bootstrap_location.workspace,
        .name = "main",
        .tabs = &.{.{
            .tab_id = TestHarness.bootstrap_location.tab_id,
            .position = 0,
            .pane_count = 1,
            .label = "main",
        }},
    });

    try std.testing.expectError(
        error.UnexpectedWorkspaceSnapshot,
        client.handleServerMessage(
            .{
                .workspace_snapshot = (try core.decodeServer(encoded)).workspace_snapshot,
            },
        ),
    );

    try std.testing.expectEqual(request_count_before, client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, TerminalClient.of(client).presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "workspace snapshot consumes an incompatible continuation before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: core.RequestId = @enumFromInt(4);
    try client.request_lifecycle.tracker.add(request_id, .notification);
    var payload: [512]u8 = undefined;
    const encoded = try core.encodeWorkspaceSnapshot(&payload, .{
        .request_id = request_id,
        .workspace = TestHarness.bootstrap_location.workspace,
        .name = "main",
        .tabs = &.{.{
            .tab_id = TestHarness.bootstrap_location.tab_id,
            .position = 0,
            .pane_count = 1,
            .label = "main",
        }},
    });
    const snapshot = (try core.decodeServer(encoded)).workspace_snapshot;

    try std.testing.expectError(error.UnexpectedWorkspaceSnapshot, client.handleServerMessage(
        .{
            .workspace_snapshot = snapshot,
        },
    ));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedWorkspaceSnapshot, client.handleServerMessage(
        .{
            .workspace_snapshot = snapshot,
        },
    ));
    try std.testing.expectEqualDeep(data.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "workspace snapshot consumes a mismatched workspace before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: core.RequestId = @enumFromInt(4);
    try client.request_lifecycle.tracker.add(request_id, .{
        .workspace_snapshot = TestHarness.bootstrap_location.workspace,
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
        client.handleServerMessage(
            .{
                .workspace_snapshot = (try core.decodeServer(encoded)).workspace_snapshot,
            },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(data.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "workspace snapshot consumes correlation before a model rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: core.RequestId = @enumFromInt(4);
    try client.request_lifecycle.tracker.add(request_id, .{
        .workspace_snapshot = TestHarness.bootstrap_location.workspace,
    });
    var payload: [512]u8 = undefined;
    const encoded = try core.encodeWorkspaceSnapshot(&payload, .{
        .request_id = request_id,
        .workspace = TestHarness.bootstrap_location.workspace,
        .name = "main",
        .tabs = &.{.{
            .tab_id = TestHarness.bootstrap_location.tab_id,
            .position = 0,
            .pane_count = 1,
            .label = "main",
        }},
    });

    try std.testing.expectError(
        error.UnexpectedWorkspace,
        client.handleServerMessage(
            .{
                .workspace_snapshot = (try core.decodeServer(encoded)).workspace_snapshot,
            },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(data.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "workspace snapshots commit semantic revisions before presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const pending_updates_before = TerminalClient.of(client).presenter.pending_updates;

    var payload: [512]u8 = undefined;
    const snapshot = try core.encodeWorkspaceSnapshot(&payload, .{
        .request_id = @enumFromInt(2),
        .workspace = TestHarness.bootstrap_location.workspace,
        .name = "main",
        .tabs = &.{
            .{ .tab_id = @enumFromInt(1), .position = 0, .pane_count = 1, .label = "main" },
            .{ .tab_id = @enumFromInt(2), .position = 1, .pane_count = 1, .label = "second" },
        },
    });
    _ = try client.handleServerMessage(
        .{
            .workspace_snapshot = (try core.decodeServer(snapshot)).workspace_snapshot,
        },
    );

    try std.testing.expectEqual(@as(usize, 2), client.model.tabs.count);
    try std.testing.expect(client.model.tabs.find(@enumFromInt(2)) != null);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqual(version_before.workspace + 1, client.model.version().workspace);
    try std.testing.expectEqual(version_before.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before, TerminalClient.of(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before + 1, TerminalClient.of(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), TerminalClient.of(client).presenter.presentation_state.prepared.model);

    const version_before_noop = client.model.version();
    const pending_updates_before_noop = TerminalClient.of(client).presenter.pending_updates;
    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{
        .workspace_snapshot = TestHarness.bootstrap_location.workspace,
    });
    const unchanged = try core.encodeWorkspaceSnapshot(&payload, .{
        .request_id = @enumFromInt(4),
        .workspace = TestHarness.bootstrap_location.workspace,
        .name = "main",
        .tabs = &.{
            .{ .tab_id = @enumFromInt(1), .position = 0, .pane_count = 1, .label = "main" },
            .{ .tab_id = @enumFromInt(2), .position = 1, .pane_count = 1, .label = "second" },
        },
    });
    _ = try client.handleServerMessage(try core.decodeServer(unchanged));
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(version_before_noop, client.model.version());
    try std.testing.expectEqual(pending_updates_before_noop, TerminalClient.of(client).presenter.pending_updates);
}

test "workspace reconciliation retires removed state and restores the new active tab" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second = try harness.addInactiveTab(@enumFromInt(2), @enumFromInt(20));
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{ .rename_tab = TestHarness.bootstrap_location });
    try TerminalClient.of(client).graphics_store.applyImage(.{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 1,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        },
    });
    try std.testing.expect(TerminalClient.of(client).graphics_store.hasPaneGraphics(TestHarness.bootstrap_pane));
    const pending_updates_before = TerminalClient.of(client).presenter.pending_updates;

    var payload: [512]u8 = undefined;
    const snapshot = try core.encodeWorkspaceSnapshot(&payload, .{
        .request_id = @enumFromInt(2),
        .workspace = TestHarness.bootstrap_location.workspace,
        .name = "main",
        .tabs = &.{
            .{ .tab_id = second.tab_id, .position = 0, .pane_count = 1, .label = "second" },
        },
    });
    _ = try client.handleServerMessage(try core.decodeServer(snapshot));

    try std.testing.expectEqualDeep(second, client.model.activeTabLocation().?);
    try std.testing.expect(!TerminalClient.of(client).graphics_store.hasPaneGraphics(TestHarness.bootstrap_pane));
    try std.testing.expect(TerminalClient.of(client).graphics_store.paneVisible(@enumFromInt(20)));
    try std.testing.expectEqual(@as(?core.PaneId, @enumFromInt(20)), support.reportedPaneId(client));
    const version_before_late_snapshot = client.model.version();
    const pending_updates_before_late_snapshot = TerminalClient.of(client).presenter.pending_updates;
    const outbox_len_before_late_snapshot = client.runtime_transport.outbox.len;
    const request_count_before_late_snapshot = client.request_lifecycle.tracker.count;
    const late_snapshot = try core.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(3),
        .location = TestHarness.bootstrap_location,
        .panes = &.{},
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try client.handleServerMessage(
            .{
                .tab_snapshot = (try core.decodeServer(late_snapshot)).tab_snapshot,
            },
        ),
    );

    try std.testing.expectEqual(request_count_before_late_snapshot - 1, client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before_late_snapshot, client.model.version());
    try std.testing.expectEqual(pending_updates_before_late_snapshot, TerminalClient.of(client).presenter.pending_updates);
    try std.testing.expectEqual(outbox_len_before_late_snapshot, client.runtime_transport.outbox.len);
    try std.testing.expect(client.request_lifecycle.tracker.take(@enumFromInt(90)).? == .ignored);
    try std.testing.expectEqual(pending_updates_before, TerminalClient.of(client).presenter.pending_updates);
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const requested = try harness.nextClientMessage(&buffer);
    try std.testing.expect(requested == .request_tab_snapshot);
    try std.testing.expectEqualDeep(second, requested.request_tab_snapshot.location);
}

test "resync required requests one workspace snapshot and coalesces repeats" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.model.workspace = TestHarness.bootstrap_location.workspace;
    const version_before = client.model.version();
    const pending_updates_before = TerminalClient.of(client).presenter.pending_updates;
    const required: core.ResyncRequired = .{
        .workspace = TestHarness.bootstrap_location.workspace,
        .workspace_closed = false,
    };

    try std.testing.expectEqual(
        @as(?u8, null),
        try client.handleServerMessage(
            .{
                .resync_required = required,
            },
        ),
    );
    try std.testing.expectEqual(
        @as(?u8, null),
        try client.handleServerMessage(
            .{
                .resync_required = required,
            },
        ),
    );
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const first = try harness.nextClientMessage(&buffer);
    try std.testing.expect(first == .request_workspace_snapshot);
    try std.testing.expect(client.request_lifecycle.tracker.has(.workspace_snapshot));
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, TerminalClient.of(client).presenter.pending_updates);
}

test "resync rejects a workspace other than the current projection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.model.workspace = TestHarness.bootstrap_location.workspace;
    const next_request_id = client.request_lifecycle.next_request_id;

    try std.testing.expectError(
        error.UnexpectedResync,
        client.handleServerMessage(
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
    try std.testing.expectEqual(next_request_id, client.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "resync keeps a closed bookmark forgotten when predecessor handoff is blocked" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.navigation_history.remember(.{
        .location = TestHarness.bootstrap_location,
        .pane_id = TestHarness.bootstrap_pane,
    });
    try client.request_lifecycle.tracker.add(@enumFromInt(7), .notification);
    const version_before = client.model.version();

    try std.testing.expectError(
        error.WorkspaceSwitchWhileRequestPending,
        client.handleServerMessage(
            .{
                .resync_required = .{
                    .workspace = TestHarness.bootstrap_location.workspace,
                    .workspace_closed = true,
                    .previous_workspace = @enumFromInt(2),
                },
            },
        ),
    );
    try std.testing.expect(
        client.navigation_history.find(TestHarness.bootstrap_location.workspace) == null,
    );
    try std.testing.expectEqual(@as(usize, 1), client.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
}

test "resync outbox failure releases its snapshot correlation so a later notice can retry" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    try client.sendRuntime(
        .{
            .detach_pane = .{
                .pane_id = TestHarness.bootstrap_pane,
            },
        },
    );
    while (client.runtime_transport.outbox.hasCapacity()) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const version = client.model.version();
    const notice: core.ResyncRequired = .{ .workspace = TestHarness.bootstrap_location.workspace, .workspace_closed = false };

    try std.testing.expectError(error.ClientOutboxFull, client.handleServerMessage(
        .{
            .resync_required = notice,
        },
    ));

    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version, client.model.version());
    try harness.settle();
    var outgoing: [256]u8 = undefined;
    for (0..data.outbox_support.capacity) |_| {
        try std.testing.expect((try harness.nextClientMessage(&outgoing)) == .detach_pane);
    }

    try std.testing.expectEqual(@as(?u8, null), try client.handleServerMessage(
        .{
            .resync_required = notice,
        },
    ));
    try std.testing.expectEqual(@as(?u8, null), try client.handleServerMessage(
        .{
            .resync_required = notice,
        },
    ));
    try std.testing.expectEqual(@as(usize, 1), client.request_lifecycle.tracker.count);
    try harness.settle();
    const recovery = try harness.nextClientMessage(&outgoing);
    try std.testing.expect(recovery == .request_workspace_snapshot);
    try std.testing.expectEqualDeep(notice.workspace, recovery.request_workspace_snapshot.workspace);
}
