//! Client integration tests for synchronization.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../../agents/root.zig");
const attachments = @import("../../attachments/root.zig");
const graphics = @import("../../graphics/root.zig");
const input_capability = @import("../../input/root.zig");
const lua_config = @import("../../config/root.zig");
const notifications = @import("../../notifications/root.zig");
const platform = @import("../../platform/root.zig");
const plugin_broker = @import("../../plugins/root.zig");
const presentation = @import("../../presentation/root.zig");
const sound_capability = @import("../../sound/root.zig");
const workspace_capability = @import("../../workspace/root.zig");
const keybind = input_capability.keybind;
const kitty = graphics.kitty;

const Io = std.Io;
const File = Io.File;
const schema = core.schema;
const term = presentation.screen;

const Client = @import("../client.zig");
const InputHandler = @import("../resources/input_handler.zig");
const active_pane_resources = @import("../controllers/panes/active_pane_resources.zig");
const client_actions = @import("../controllers/input/actions.zig");
const agent_navigation = @import("../controllers/agents/agent_navigation.zig");
const agent_sounds = @import("../controllers/agents/agent_sounds.zig");
const session_application = @import("../application/session/root.zig");
const client_events = @import("../entrypoints/events.zig");
const client_startup = @import("../controllers/session/client_startup.zig");
const client_outbox = @import("../connection/outbox.zig");
const client_model = @import("../model/root.zig");
const client_telemetry = @import("../resources/telemetry.zig");
const clipboard_images = @import("../controllers/host/clipboard_images.zig");
const client_clock = @import("../resources/clock.zig");
const config_reload_worker = @import("../resources/config_reload.zig");
const config_reloads = @import("../controllers/configuration/config_reloads.zig");
const host_capabilities = @import("../controllers/host/host_capabilities.zig");
const host_inputs = @import("../controllers/input/host_inputs.zig");
const host_resizes = @import("../controllers/host/host_resizes.zig");
const name_prompts = @import("../controllers/input/name_prompts.zig");
const notification_flow = @import("../controllers/notifications/notifications.zig");
const pane_clipboards = @import("../controllers/panes/pane_clipboards.zig");
const pane_closures = @import("../controllers/panes/pane_closures.zig");
const pane_focus = @import("../controllers/panes/pane_focus.zig");
const pane_focus_reports = @import("../controllers/panes/pane_focus_reports.zig");
const pane_geometry = @import("../controllers/panes/pane_geometry.zig");
const pane_openings = @import("../controllers/panes/pane_openings.zig");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const plugin_actions = @import("../controllers/configuration/plugin_actions.zig");
const request_lifecycle = @import("../connection/request_lifecycle.zig");
const resync_requirements = @import("../controllers/session/resync_requirements.zig");
const runtime_transport = @import("../connection/runtime_transport.zig");
const server_messages = @import("../entrypoints/runtime_messages.zig");
const sidebar_animations = @import("../controllers/notifications/sidebar_animations.zig");
const sidebar_projection = @import("../controllers/notifications/sidebar_projection.zig");
const tab_attachments = @import("../controllers/tabs/tab_attachments.zig");
const tab_closures = @import("../controllers/tabs/tab_closures.zig");
const tab_creations = @import("../controllers/tabs/tab_creations.zig");
const tab_moves = @import("../controllers/tabs/tab_moves.zig");
const tab_renames = @import("../controllers/tabs/tab_renames.zig");
const tab_snapshots = @import("../controllers/tabs/tab_snapshots.zig");
const workspace_handoffs = @import("../controllers/workspaces/workspace_handoffs.zig");
const workspace_snapshots = @import("../controllers/workspaces/workspace_snapshots.zig");
const InputChunk = Client.InputChunk;
const initial_request_id = request_lifecycle.initial_request_id;

const support = @import("support.zig");

const clientEventResourcesForTest = support.clientEventResourcesForTest;
const reportedPaneId = support.reportedPaneId;
const expectNonPromptVersionEqual = support.expectNonPromptVersionEqual;
const expectNonCopyVersionEqual = support.expectNonCopyVersionEqual;
const expectNonCopyOrViewportVersionEqual = support.expectNonCopyOrViewportVersionEqual;
const expectNonViewportVersionEqual = support.expectNonViewportVersionEqual;
const expectOnlyNotificationVersionChanged = support.expectOnlyNotificationVersionChanged;
const TestHarness = support.TestHarness;
const encodeTestingAgentSnapshot = support.encodeTestingAgentSnapshot;
const testingConfigAdoption = support.testingConfigAdoption;
const testingConfigAdoptionSource = support.testingConfigAdoptionSource;
const installTestingLuaBinding = support.installTestingLuaBinding;
const TestingPlugin = support.TestingPlugin;
const testing_plugin_context = support.testing_plugin_context;
const installTestingPlugin = support.installTestingPlugin;
const installTestingAttachmentTarget = support.installTestingAttachmentTarget;
const testingClipboardCapture = support.testingClipboardCapture;

test "pane opening rejects an unknown request without client effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;

    try std.testing.expectError(error.UnexpectedRequest, pane_openings.apply(client, .{
        .request_id = @enumFromInt(99),
        .pane_id = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .created = true,
    }));

    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
}

test "pane opening consumes an incompatible continuation before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: schema.RequestId = @enumFromInt(4);
    const opened: schema.PaneOpened = .{
        .request_id = request_id,
        .pane_id = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .created = true,
    };
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    try client.request_lifecycle.tracker.add(request_id, .notification);

    try std.testing.expectError(error.UnexpectedRequest, pane_openings.apply(client, opened));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedRequest, pane_openings.apply(client, opened));
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
}

test "pane opening consumes an ignored continuation without client effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: schema.RequestId = @enumFromInt(4);
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    try client.request_lifecycle.tracker.add(request_id, .ignored);

    try std.testing.expectEqual(pane_openings.Outcome.ignored, try pane_openings.apply(client, .{
        .request_id = request_id,
        .pane_id = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .created = false,
    }));

    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
}

test "new tab request captures launch source geometry and continuation without mutation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    harness.client.options.arguments = &.{"/bin/sh"};
    const version_before_request = harness.client.model.version();
    const pending_updates_before_request = harness.client.presenter.pending_updates;

    const handler: InputHandler = .{ .client = harness.client };
    _ = try client_actions.apply(handler.client, .new_tab);
    try harness.settle();

    var buffer: [512]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .create_tab);
    const created = message.create_tab;
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location.workspace, created.workspace);
    try std.testing.expectEqualStrings("", created.label);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, created.launch.cwd_source.?);
    try std.testing.expectEqual(schema.TerminalSize{
        .cols = harness.client.view.workbench().w,
        .rows = harness.client.view.workbench().h,
    }, created.size);
    try std.testing.expectEqualDeep(version_before_request, harness.client.model.version());
    try std.testing.expectEqual(pending_updates_before_request, harness.client.presenter.pending_updates);

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

    const handler: InputHandler = .{ .client = harness.client };
    _ = try client_actions.apply(handler.client, .{ .split_pane = .horizontal });
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

    var handler: InputHandler = .{ .client = harness.client };
    _ = try client_actions.apply(handler.client, .new_workspace);
    try handler.forward("agents\r");
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

    const destination: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(2) };
    const restored_pane: schema.PaneId = @enumFromInt(77);
    client.navigation_history.remember(.{
        .location = .{ .workspace = destination, .tab_id = @enumFromInt(8) },
        .pane_id = restored_pane,
    });
    const version_before_departure = client.model.version();
    const pending_updates_before_departure = client.presenter.pending_updates;
    _ = try workspace_handoffs.requestWorkspace(client, @enumFromInt(2));

    try std.testing.expect(client.model.workspaceLocation() == null);
    try std.testing.expectEqual(@as(usize, 0), client.model.workspace.count);
    try std.testing.expectEqual(version_before_departure.workspace + 1, client.model.version().workspace);
    try std.testing.expectEqual(version_before_departure.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_departure.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(version_before_departure.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_departure, client.presenter.pending_updates);
    try std.testing.expect(client.model.reportedPaneFocus() == null);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_departure + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try harness.settle();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
    try std.testing.expectEqual(@as(usize, 0), client.presenter.pending_updates);
    for (client.presenter.screen.front.cells) |cell| {
        try std.testing.expectEqualStrings(" ", cell.text());
        try std.testing.expectEqual(@as(u8, 1), cell.width);
    }
    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(@as(usize, 0), client.presenter.pending_updates);

    var buffer: [256]u8 = undefined;
    var target: ?schema.PaneTarget = null;
    var request_id: schema.RequestId = .none;
    while (target == null) switch (try harness.nextClientMessage(&buffer)) {
        .detach_pane => {},
        .open_pane => |open| {
            request_id = open.request_id;
            target = open.target;
        },
        else => return error.UnexpectedClientMessage,
    };
    try std.testing.expectEqualDeep(schema.PaneTarget{ .pane = restored_pane }, target.?);
    const current = client.navigation_history.find(TestHarness.bootstrap_location.workspace).?;
    try std.testing.expectEqual(TestHarness.bootstrap_pane, current.pane_id);
    try std.testing.expect(current.tab_layout != null);

    var payload: [128]u8 = undefined;
    const failed = try schema.encodeRequestFailed(&payload, .{
        .request_id = request_id,
        .code = .pane_not_found,
        .message = "remembered pane closed",
    });
    const version_before_recovery = client.model.version();
    const pending_updates_before_recovery = client.presenter.pending_updates;
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(failed));

    try std.testing.expectEqualDeep(version_before_recovery, client.model.version());
    try std.testing.expectEqual(pending_updates_before_recovery, client.presenter.pending_updates);
    try harness.settle();
    const fallback = (try harness.nextClientMessage(&buffer)).open_pane;
    try std.testing.expectEqualDeep(
        schema.PaneTarget{ .workspace = @enumFromInt(2) },
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
    while (client.runtime_transport.outbox.len < client_outbox.capacity - 1) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const version_before = client.model.version();
    const focus_before = client.model.reportedPaneFocus();
    const next_request_id = client.request_lifecycle.next_request_id;

    try std.testing.expectError(
        error.ClientOutboxFull,
        workspace_handoffs.requestWorkspace(client, @enumFromInt(2)),
    );

    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqualDeep(focus_before, client.model.reportedPaneFocus());
    try std.testing.expect(client.navigation_history.find(TestHarness.bootstrap_location.workspace) == null);
    try std.testing.expectEqual(next_request_id, client.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqual(client_outbox.capacity - 1, @as(usize, client.runtime_transport.outbox.len));
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
        workspace_handoffs.requestWorkspace(client, @enumFromInt(2)),
    );

    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
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
    client.model.workspace.findPane(TestHarness.bootstrap_pane).?.input_modes.focus_events = true;
    try active_pane_resources.synchronize(client);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const focus_in = try harness.nextClientMessage(&buffer);
    try std.testing.expect(focus_in == .pane_input);
    try std.testing.expectEqualStrings("\x1b[I", focus_in.pane_input.bytes);
    while (client.runtime_transport.outbox.len < client_outbox.capacity - 2) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const version = client.model.version();
    const reported = client.model.reportedPaneFocus();

    try std.testing.expectError(
        error.ClientOutboxFull,
        workspace_handoffs.requestWorkspace(client, @enumFromInt(2)),
    );

    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqualDeep(reported, client.model.reportedPaneFocus());
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
}

test "workspace handoff reserves its captured paste closing marker" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    client.model.workspace.findPane(TestHarness.bootstrap_pane).?.input_modes.bracketed_paste = true;
    var input_handler: InputHandler = .{ .client = client };
    try input_handler.pasteStart();
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const opening = try harness.nextClientMessage(&buffer);
    try std.testing.expect(opening == .pane_input);
    try std.testing.expectEqualStrings("\x1b[200~", opening.pane_input.bytes);
    while (client.runtime_transport.outbox.len < client_outbox.capacity - 2) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const version = client.model.version();

    try std.testing.expectError(
        error.ClientOutboxFull,
        workspace_handoffs.requestWorkspace(client, @enumFromInt(2)),
    );

    try std.testing.expect(client.model.panePasteActive());
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
}

test "clicking a sidebar agent hands off directly to its pane" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};

    const agent_pane: schema.PaneId = @enumFromInt(91);
    const agent = agents.AgentInput{
        .key = .{ .pane_id = agent_pane, .pane_generation = 2 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(3) },
            .tab_id = @enumFromInt(6),
        },
        .pane_index = 2,
        .provider = .claude,
        .status = .working,
    };
    const left_pane: schema.PaneId = @enumFromInt(90);
    const bottom_right_pane: schema.PaneId = @enumFromInt(92);
    var saved_layout: workspace_capability.layout.Layout = .{};
    try saved_layout.addRoot(left_pane);
    try saved_layout.split(left_pane, agent_pane, .horizontal);
    try saved_layout.split(agent_pane, bottom_right_pane, .vertical);
    client.navigation_history.remember(.{
        .location = agent.location,
        .pane_id = agent_pane,
        .tab_layout = saved_layout,
    });
    _ = try client.model.reconcileAgentSnapshot(.{
        .revision = 1,
        .agents = &.{agent},
    });
    const model = &client.model.workspace.active().?.model;
    _ = try client.view.render(&client.presenter.screen, .{
        .tabs = &client.model.workspace,
        .model = model,
        .agents = client.model.agentSnapshot(),
        .force = true,
    });
    var handler: InputHandler = .{ .client = client };
    try handler.mouse(.{ .x = 4, .y = 4, .kind = .press });
    try harness.settle();

    var buffer: [256]u8 = undefined;
    var target: ?schema.PaneTarget = null;
    var request_id: schema.RequestId = .none;
    while (target == null) switch (try harness.nextClientMessage(&buffer)) {
        .detach_pane => {},
        .open_pane => |open| {
            request_id = open.request_id;
            target = open.target;
        },
        else => return error.UnexpectedClientMessage,
    };
    try std.testing.expectEqualDeep(schema.PaneTarget{ .pane = agent_pane }, target.?);

    var payload: [128]u8 = undefined;
    const opened = try schema.encodePaneOpened(&payload, .{
        .request_id = request_id,
        .pane_id = agent_pane,
        .location = agent.location,
        .created = false,
    });
    const version_before_arrival = client.model.version();
    const pending_updates_before_arrival = client.presenter.pending_updates;
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(opened));

    try std.testing.expectEqual(version_before_arrival.workspace + 1, client.model.version().workspace);
    try std.testing.expectEqual(version_before_arrival.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_arrival.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(version_before_arrival.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_arrival, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_arrival + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try harness.settle();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
    try std.testing.expectEqualDeep(
        @as(?schema.WorkspaceLocation, agent.location.workspace),
        client.model.workspace.workspace,
    );
    try std.testing.expectEqual(agent.location.tab_id, client.model.workspace.activeConst().?.location.tab_id);
    try std.testing.expectEqual(agent_pane, client.model.workspace.activeConst().?.model.layout.focused().?);

    var tab_snapshot_request: schema.RequestId = .none;
    while (tab_snapshot_request == .none) switch (try harness.nextClientMessage(&buffer)) {
        .request_workspace_snapshot => {},
        .request_tab_snapshot => |request| {
            try std.testing.expectEqualDeep(agent.location, request.location);
            tab_snapshot_request = request.request_id;
        },
        else => return error.UnexpectedClientMessage,
    };
    var snapshot_payload: [256]u8 = undefined;
    const snapshot = try schema.encodeTabSnapshot(&snapshot_payload, .{
        .request_id = tab_snapshot_request,
        .location = agent.location,
        .panes = &.{
            .{ .pane_id = left_pane, .lifecycle = .running },
            .{ .pane_id = agent_pane, .lifecycle = .running },
            .{ .pane_id = bottom_right_pane, .lifecycle = .running },
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(snapshot));

    const restored = &client.model.workspace.activeConst().?.model;
    try std.testing.expectEqual(agent_pane, restored.layout.focused().?);
    try std.testing.expectEqual(@as(u16, 2), restored.displayIndex(agent_pane).?);
    var expected_geometry: workspace_capability.layout.Snapshot = .{};
    var actual_geometry: workspace_capability.layout.Snapshot = .{};
    saved_layout.snapshot(client.view.workbench(), &expected_geometry);
    restored.layout.snapshot(client.view.workbench(), &actual_geometry);
    for ([_]schema.PaneId{ left_pane, agent_pane, bottom_right_pane }) |pane_id|
        try std.testing.expectEqual(
            expected_geometry.find(pane_id).?.outer,
            actual_geometry.find(pane_id).?.outer,
        );
}

test "local agent navigation selects its tab before focusing its pane" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    try harness.allowTabSelection();
    const client = harness.client;
    const agent_pane: schema.PaneId = @enumFromInt(20);
    const location = try harness.addInactiveTab(@enumFromInt(2), agent_pane);
    const key: agents.AgentKey = .{
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
    const pending_updates = client.presenter.pending_updates;

    try std.testing.expectEqual(
        agent_navigation.Outcome.focused,
        try agent_navigation.apply(client, key),
    );

    try std.testing.expectEqualDeep(location, client.model.activeTabLocation().?);
    try std.testing.expectEqual(agent_pane, client.model.workspace.activeConst().?.model.layout.focused().?);
    try std.testing.expectEqual(version.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(version.panes, client.model.version().panes);
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);

    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, detached.detach_pane.pane_id);
    const snapshot = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(snapshot == .request_tab_snapshot);
    try std.testing.expectEqualDeep(location, snapshot.request_tab_snapshot.location);
}

test "tab snapshots commit pane revisions before attaching and presenting" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;

    const discovered: schema.PaneId = @enumFromInt(11);
    var payload: [256]u8 = undefined;
    const snapshot = try schema.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(3),
        .location = TestHarness.bootstrap_location,
        .panes = &.{
            .{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running },
            .{ .pane_id = discovered, .lifecycle = .running },
        },
    });
    try std.testing.expectEqual(
        tab_snapshots.Outcome.applied,
        try tab_snapshots.apply(client, (try schema.decodeServer(snapshot)).tab_snapshot),
    );

    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(version_before.workspace, client.model.version().workspace);
    try std.testing.expectEqual(version_before.tabs, client.model.version().tabs);
    try std.testing.expectEqual(version_before.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    const committed_version = client.model.version();
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{ .tab_snapshot = TestHarness.bootstrap_location });
    const repeated = try schema.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(90),
        .location = TestHarness.bootstrap_location,
        .panes = &.{
            .{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running },
            .{ .pane_id = discovered, .lifecycle = .running },
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(repeated));

    try std.testing.expectEqualDeep(committed_version, client.model.version());
    try std.testing.expect(client.request_lifecycle.tracker.hasPane(.attachment, discovered));
    try std.testing.expectEqual(@as(usize, 2), client.request_lifecycle.tracker.count);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before + 1, client.presenter.pending_updates);
    try harness.settle();

    const pane = client.model.workspace.findPane(discovered).?;
    try std.testing.expect(!pane.attached);
    var buffer: [256]u8 = undefined;
    var attach_requested = false;
    while (!attach_requested) {
        switch (try harness.nextClientMessage(&buffer)) {
            .open_pane => |open| {
                try std.testing.expectEqualDeep(
                    schema.PaneTarget{ .pane = discovered },
                    open.target,
                );
                attach_requested = true;
            },
            .pane_resize => {},
            else => return error.UnexpectedClientMessage,
        }
    }

    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
}

test "an identical tab snapshot repairs resources without scheduling a frame" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    var payload: [256]u8 = undefined;
    const initial = try schema.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(3),
        .location = TestHarness.bootstrap_location,
        .panes = &.{.{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running }},
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(initial));
    try presentation_lifecycle.observe(client);
    try harness.settle();
    try harness.settleModelPresentation();
    const committed_version = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{ .tab_snapshot = TestHarness.bootstrap_location });
    const unchanged = try schema.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(90),
        .location = TestHarness.bootstrap_location,
        .panes = &.{.{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running }},
    });

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(unchanged));
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(committed_version, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
}

test "tab reconciliation retires removed pane resources and continuations" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    var payload: [256]u8 = undefined;
    const initial = try schema.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(3),
        .location = TestHarness.bootstrap_location,
        .panes = &.{.{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running }},
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(initial));
    try harness.settle();

    const retired: schema.PaneId = @enumFromInt(11);
    const model = &client.model.workspace.active().?.model;
    try model.split(
        TestHarness.bootstrap_pane,
        retired,
        TestHarness.bootstrap_location,
        .horizontal,
        client.view.workbench(),
    );
    try active_pane_resources.synchronize(client);
    try std.testing.expect(client.model.enterCopyMode());
    try client.graphics_store.applyImage(.{
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
    const pending_updates_before = client.presenter.pending_updates;
    const reconciled = try schema.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(90),
        .location = TestHarness.bootstrap_location,
        .panes = &.{.{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running }},
    });

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(reconciled));

    try std.testing.expect(client.model.workspace.findPane(retired) == null);
    try std.testing.expect(!client.graphics_store.hasPaneGraphics(retired));
    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expectEqual(@as(?schema.PaneId, TestHarness.bootstrap_pane), reportedPaneId(client));
    try std.testing.expect(client.request_lifecycle.tracker.take(@enumFromInt(91)).? == .ignored);
    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before + 1, client.presenter.pending_updates);
}

test "an unexpected tab snapshot is rejected instead of adopted" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();

    const client = harness.client;
    const version_before = client.model.version();
    const request_count_before = client.request_lifecycle.tracker.count;
    const pending_updates_before = client.presenter.pending_updates;
    var payload: [256]u8 = undefined;
    const snapshot = try schema.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(99),
        .location = TestHarness.bootstrap_location,
        .panes = &.{},
    });
    try std.testing.expectError(
        error.UnexpectedTabSnapshot,
        server_messages.handleServerMessage(client, try schema.decodeServer(snapshot)),
    );

    try std.testing.expectEqual(request_count_before, client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "tab snapshot consumes an incompatible continuation before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: schema.RequestId = @enumFromInt(4);
    try client.request_lifecycle.tracker.add(request_id, .notification);
    var payload: [256]u8 = undefined;
    const encoded = try schema.encodeTabSnapshot(&payload, .{
        .request_id = request_id,
        .location = TestHarness.bootstrap_location,
        .panes = &.{},
    });
    const snapshot = (try schema.decodeServer(encoded)).tab_snapshot;

    try std.testing.expectError(error.UnexpectedTabSnapshot, tab_snapshots.apply(client, snapshot));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabSnapshot, tab_snapshots.apply(client, snapshot));
    try std.testing.expectEqualDeep(client_model.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "tab snapshot consumes a mismatched location before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: schema.RequestId = @enumFromInt(4);
    try client.request_lifecycle.tracker.add(request_id, .{ .tab_snapshot = TestHarness.bootstrap_location });
    var payload: [256]u8 = undefined;
    const encoded = try schema.encodeTabSnapshot(&payload, .{
        .request_id = request_id,
        .location = .{
            .workspace = TestHarness.bootstrap_location.workspace,
            .tab_id = @enumFromInt(2),
        },
        .panes = &.{},
    });

    try std.testing.expectError(
        error.UnexpectedTabSnapshot,
        tab_snapshots.apply(client, (try schema.decodeServer(encoded)).tab_snapshot),
    );
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(client_model.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "tab snapshot consumes correlation before a model rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: schema.RequestId = @enumFromInt(4);
    try client.request_lifecycle.tracker.add(request_id, .{ .tab_snapshot = TestHarness.bootstrap_location });
    var payload: [256]u8 = undefined;
    const encoded = try schema.encodeTabSnapshot(&payload, .{
        .request_id = request_id,
        .location = TestHarness.bootstrap_location,
        .panes = &.{},
    });

    try std.testing.expectError(
        error.UnexpectedTab,
        tab_snapshots.apply(client, (try schema.decodeServer(encoded)).tab_snapshot),
    );
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(client_model.Version{}, client.model.version());
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
    const pending_updates_before = client.presenter.pending_updates;
    var payload: [512]u8 = undefined;
    const encoded = try schema.encodeWorkspaceSnapshot(&payload, .{
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
        workspace_snapshots.apply(client, (try schema.decodeServer(encoded)).workspace_snapshot),
    );

    try std.testing.expectEqual(request_count_before, client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "workspace snapshot consumes an incompatible continuation before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: schema.RequestId = @enumFromInt(4);
    try client.request_lifecycle.tracker.add(request_id, .notification);
    var payload: [512]u8 = undefined;
    const encoded = try schema.encodeWorkspaceSnapshot(&payload, .{
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
    const snapshot = (try schema.decodeServer(encoded)).workspace_snapshot;

    try std.testing.expectError(error.UnexpectedWorkspaceSnapshot, workspace_snapshots.apply(client, snapshot));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedWorkspaceSnapshot, workspace_snapshots.apply(client, snapshot));
    try std.testing.expectEqualDeep(client_model.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "workspace snapshot consumes a mismatched workspace before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: schema.RequestId = @enumFromInt(4);
    try client.request_lifecycle.tracker.add(request_id, .{
        .workspace_snapshot = TestHarness.bootstrap_location.workspace,
    });
    var payload: [512]u8 = undefined;
    const encoded = try schema.encodeWorkspaceSnapshot(&payload, .{
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
        workspace_snapshots.apply(client, (try schema.decodeServer(encoded)).workspace_snapshot),
    );
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(client_model.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "workspace snapshot consumes correlation before a model rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: schema.RequestId = @enumFromInt(4);
    try client.request_lifecycle.tracker.add(request_id, .{
        .workspace_snapshot = TestHarness.bootstrap_location.workspace,
    });
    var payload: [512]u8 = undefined;
    const encoded = try schema.encodeWorkspaceSnapshot(&payload, .{
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
        workspace_snapshots.apply(client, (try schema.decodeServer(encoded)).workspace_snapshot),
    );
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(client_model.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "workspace snapshots commit semantic revisions before presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;

    var payload: [512]u8 = undefined;
    const snapshot = try schema.encodeWorkspaceSnapshot(&payload, .{
        .request_id = @enumFromInt(2),
        .workspace = TestHarness.bootstrap_location.workspace,
        .name = "main",
        .tabs = &.{
            .{ .tab_id = @enumFromInt(1), .position = 0, .pane_count = 1, .label = "main" },
            .{ .tab_id = @enumFromInt(2), .position = 1, .pane_count = 1, .label = "second" },
        },
    });
    try workspace_snapshots.apply(client, (try schema.decodeServer(snapshot)).workspace_snapshot);

    try std.testing.expectEqual(@as(usize, 2), client.model.workspace.count);
    try std.testing.expect(client.model.workspace.find(@enumFromInt(2)) != null);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqual(version_before.workspace + 1, client.model.version().workspace);
    try std.testing.expectEqual(version_before.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    const version_before_noop = client.model.version();
    const pending_updates_before_noop = client.presenter.pending_updates;
    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{
        .workspace_snapshot = TestHarness.bootstrap_location.workspace,
    });
    const unchanged = try schema.encodeWorkspaceSnapshot(&payload, .{
        .request_id = @enumFromInt(4),
        .workspace = TestHarness.bootstrap_location.workspace,
        .name = "main",
        .tabs = &.{
            .{ .tab_id = @enumFromInt(1), .position = 0, .pane_count = 1, .label = "main" },
            .{ .tab_id = @enumFromInt(2), .position = 1, .pane_count = 1, .label = "second" },
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(unchanged));
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(version_before_noop, client.model.version());
    try std.testing.expectEqual(pending_updates_before_noop, client.presenter.pending_updates);
}

test "workspace reconciliation retires removed state and restores the new active tab" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second = try harness.addInactiveTab(@enumFromInt(2), @enumFromInt(20));
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{ .rename_tab = TestHarness.bootstrap_location });
    try client.graphics_store.applyImage(.{
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
    try std.testing.expect(client.graphics_store.hasPaneGraphics(TestHarness.bootstrap_pane));
    const pending_updates_before = client.presenter.pending_updates;

    var payload: [512]u8 = undefined;
    const snapshot = try schema.encodeWorkspaceSnapshot(&payload, .{
        .request_id = @enumFromInt(2),
        .workspace = TestHarness.bootstrap_location.workspace,
        .name = "main",
        .tabs = &.{
            .{ .tab_id = second.tab_id, .position = 0, .pane_count = 1, .label = "second" },
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(snapshot));

    try std.testing.expectEqualDeep(second, client.model.activeTabLocation().?);
    try std.testing.expect(!client.graphics_store.hasPaneGraphics(TestHarness.bootstrap_pane));
    try std.testing.expect(client.graphics_store.paneVisible(@enumFromInt(20)));
    try std.testing.expectEqual(@as(?schema.PaneId, @enumFromInt(20)), reportedPaneId(client));
    const version_before_late_snapshot = client.model.version();
    const pending_updates_before_late_snapshot = client.presenter.pending_updates;
    const outbox_len_before_late_snapshot = client.runtime_transport.outbox.len;
    const request_count_before_late_snapshot = client.request_lifecycle.tracker.count;
    const late_snapshot = try schema.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(3),
        .location = TestHarness.bootstrap_location,
        .panes = &.{},
    });
    try std.testing.expectEqual(
        tab_snapshots.Outcome.ignored,
        try tab_snapshots.apply(client, (try schema.decodeServer(late_snapshot)).tab_snapshot),
    );

    try std.testing.expectEqual(request_count_before_late_snapshot - 1, client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before_late_snapshot, client.model.version());
    try std.testing.expectEqual(pending_updates_before_late_snapshot, client.presenter.pending_updates);
    try std.testing.expectEqual(outbox_len_before_late_snapshot, client.runtime_transport.outbox.len);
    try std.testing.expect(client.request_lifecycle.tracker.take(@enumFromInt(90)).? == .ignored);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
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
    client.model.workspace.workspace = TestHarness.bootstrap_location.workspace;
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    const required: schema.ResyncRequired = .{
        .workspace = TestHarness.bootstrap_location.workspace,
        .workspace_closed = false,
    };

    try std.testing.expectEqual(
        session_application.resync_required.Outcome.snapshot_requested,
        try resync_requirements.apply(client, required),
    );
    try std.testing.expectEqual(
        session_application.resync_required.Outcome.coalesced,
        try resync_requirements.apply(client, required),
    );
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const first = try harness.nextClientMessage(&buffer);
    try std.testing.expect(first == .request_workspace_snapshot);
    try std.testing.expect(client.request_lifecycle.tracker.has(.workspace_snapshot));
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
}

test "resync rejects a workspace other than the current projection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.model.workspace.workspace = TestHarness.bootstrap_location.workspace;
    const next_request_id = client.request_lifecycle.next_request_id;

    try std.testing.expectError(
        error.UnexpectedResync,
        resync_requirements.apply(client, .{
            .workspace = .{ .workspace = @enumFromInt(9) },
            .workspace_closed = false,
        }),
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
        resync_requirements.apply(client, .{
            .workspace = TestHarness.bootstrap_location.workspace,
            .workspace_closed = true,
            .previous_workspace = @enumFromInt(2),
        }),
    );
    try std.testing.expect(
        client.navigation_history.find(TestHarness.bootstrap_location.workspace) == null,
    );
    try std.testing.expectEqual(@as(usize, 1), client.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
}
