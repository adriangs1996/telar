//! Client integration tests for workspace lifecycle.

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

test "a created workspace bookmarks and replaces the prior layout" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    const prior_location = TestHarness.bootstrap_location;
    const left = TestHarness.bootstrap_pane;
    const top_right: schema.PaneId = @enumFromInt(11);
    const bottom_right: schema.PaneId = @enumFromInt(12);
    const workbench = client.view.workbench();
    const prior_model = &client.model.workspace.active().?.model;
    try prior_model.split(.{ .existing_pane = left, .new_pane = top_right, .location = prior_location, .axis = .horizontal, .area = workbench });
    try prior_model.split(.{ .existing_pane = top_right, .new_pane = bottom_right, .location = prior_location, .axis = .vertical, .area = workbench });
    prior_model.find(left).?.input_modes.focus_events = true;
    try std.testing.expect(prior_model.focusPane(left));
    _ = client.model.syncReportedPaneFocus().?;
    try std.testing.expect(prior_model.focusPane(bottom_right));
    var expected_geometry: workspace_capability.layout.Snapshot = .{};
    prior_model.layout.snapshot(workbench, &expected_geometry);

    const new_location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(5),
    };
    const version_before_creation = client.model.version();
    const pending_updates_before_creation = client.presenter.pending_updates;
    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .create_workspace = .{ .cols = 80, .rows = 20 } });
    var payload: [128]u8 = undefined;
    const opened = try schema.encodePaneOpened(&payload, .{
        .request_id = @enumFromInt(4),
        .pane_id = @enumFromInt(30),
        .location = new_location,
        .created = true,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(opened));

    try std.testing.expect(!client.notification_scheduler.pending);
    try std.testing.expectEqualDeep(
        @as(?schema.WorkspaceLocation, new_location.workspace),
        client.model.workspace.workspace,
    );
    const created_pane = client.model.workspace.findPane(@enumFromInt(30)).?;
    try std.testing.expectEqual(@as(u16, 80), created_pane.buffer.w);
    try std.testing.expectEqual(@as(u16, 20), created_pane.buffer.h);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane) == null);
    try std.testing.expectEqual(version_before_creation.workspace + 1, client.model.version().workspace);
    try std.testing.expectEqual(version_before_creation.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_creation.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(version_before_creation.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_creation, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(?schema.PaneId, @enumFromInt(30)), reportedPaneId(client));

    const bookmark = client.navigation_history.find(prior_location.workspace).?;
    try std.testing.expectEqual(prior_location, bookmark.location);
    try std.testing.expectEqual(bottom_right, bookmark.pane_id);
    const saved_layout = bookmark.tab_layout.?;
    var saved_geometry: workspace_capability.layout.Snapshot = .{};
    saved_layout.snapshot(workbench, &saved_geometry);
    for ([_]schema.PaneId{ left, top_right, bottom_right }) |pane_id|
        try std.testing.expectEqual(
            expected_geometry.find(pane_id).?.outer,
            saved_geometry.find(pane_id).?.outer,
        );

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates_before_creation + 1, client.presenter.pending_updates);
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const workspace_snapshot = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(workspace_snapshot == .request_workspace_snapshot);
    try std.testing.expectEqualDeep(new_location.workspace, workspace_snapshot.request_workspace_snapshot.workspace);
    const tab_snapshot = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(tab_snapshot == .request_tab_snapshot);
    try std.testing.expectEqualDeep(new_location, tab_snapshot.request_tab_snapshot.location);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    // Return through the same runtime handoff used by workspace selection.
    client.request_lifecycle.tracker = .{};
    _ = try workspace_handoffs.requestWorkspace(client, prior_location.workspace.workspace);
    try harness.settle();
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(30)), detached.detach_pane.pane_id);
    const open = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(open == .open_pane);
    try std.testing.expectEqualDeep(schema.PaneTarget{ .pane = bottom_right }, open.open_pane.target);
    const open_request = open.open_pane.request_id;

    const reopened = try schema.encodePaneOpened(&payload, .{
        .request_id = open_request,
        .pane_id = bottom_right,
        .location = prior_location,
        .created = false,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(reopened));
    try harness.settle();
    var snapshot_request: schema.RequestId = .none;
    while (snapshot_request == .none) switch (try harness.nextClientMessage(&message_buffer)) {
        .request_workspace_snapshot => {},
        .request_tab_snapshot => |request| {
            try std.testing.expectEqual(prior_location, request.location);
            snapshot_request = request.request_id;
        },
        else => return error.UnexpectedClientMessage,
    };
    var snapshot_payload: [256]u8 = undefined;
    const snapshot = try schema.encodeTabSnapshot(&snapshot_payload, .{
        .request_id = snapshot_request,
        .location = prior_location,
        .panes = &.{
            .{ .pane_id = left, .lifecycle = .running },
            .{ .pane_id = top_right, .lifecycle = .running },
            .{ .pane_id = bottom_right, .lifecycle = .running },
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(snapshot));

    var restored_geometry: workspace_capability.layout.Snapshot = .{};
    client.model.workspace.activeConst().?.model.layout.snapshot(workbench, &restored_geometry);
    for ([_]schema.PaneId{ left, top_right, bottom_right }) |pane_id|
        try std.testing.expectEqual(
            expected_geometry.find(pane_id).?.outer,
            restored_geometry.find(pane_id).?.outer,
        );
}

test "a failed workspace creation preserves the current projection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const version_before_failure = client.model.version();
    const location_before_failure = client.model.activeTabLocation().?;

    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .create_workspace = .{ .cols = 80, .rows = 20 } });
    var payload: [256]u8 = undefined;
    const failed = try schema.encodeRequestFailed(&payload, .{
        .request_id = @enumFromInt(4),
        .code = .spawn_failed,
        .message = "shell launch failed",
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(failed));

    try expectOnlyNotificationVersionChanged(version_before_failure, client.model.version());
    try std.testing.expectEqualDeep(location_before_failure, client.model.activeTabLocation().?);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane) != null);
    try std.testing.expect(client.notification_scheduler.pending);
}
