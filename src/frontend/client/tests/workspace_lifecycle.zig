//! Client integration tests for workspace lifecycle.

const TerminalClient = @import("../TerminalClient.zig");
const host = TerminalClient.of;
const TestHarness = @import("TestHarness.zig");
const PaneIdType = @import("telar-core").PaneId;
const std = @import("std");
const LayoutSnapshot = @import("telar-client").LayoutSnapshot;
const TabLocationType = @import("telar-core").TabLocation;
const encodePaneOpened_module = @import("telar-core").encodePaneOpened;
const server_messages = @import("telar-client").server_messages;
const decodeServer_module = @import("telar-core").decodeServer;
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const support = @import("support.zig");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const workspace_handoffs = @import("telar-client").controllers.workspace_handoffs;
const PaneTargetType = @import("telar-core").PaneTarget;
const RequestIdType = @import("telar-core").RequestId;
const encodeTabSnapshot_module = @import("telar-core").encodeTabSnapshot;
const encodeRequestFailed_module = @import("telar-core").encodeRequestFailed;

test "a created workspace bookmarks and replaces the prior layout" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    const prior_location = TestHarness.bootstrap_location;
    const left = TestHarness.bootstrap_pane;
    const top_right: PaneIdType = @enumFromInt(11);
    const bottom_right: PaneIdType = @enumFromInt(12);
    const workbench = host(client).view.workbench();
    const prior_model = &client.model.workspace.active().?.model;
    try prior_model.split(.{ .existing_pane = left, .new_pane = top_right, .location = prior_location, .axis = .horizontal, .area = workbench });
    try prior_model.split(.{ .existing_pane = top_right, .new_pane = bottom_right, .location = prior_location, .axis = .vertical, .area = workbench });
    prior_model.find(left).?.input_modes.focus_events = true;
    try std.testing.expect(prior_model.focusPane(left));
    _ = client.model.syncReportedPaneFocus().?;
    try std.testing.expect(prior_model.focusPane(bottom_right));
    var expected_geometry: LayoutSnapshot = .{};
    prior_model.layout.snapshot(workbench, &expected_geometry);

    const new_location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(5),
    };
    const version_before_creation = client.model.version();
    const pending_updates_before_creation = host(client).presenter.pending_updates;
    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .create_workspace = .{ .cols = 80, .rows = 20 } });
    var payload: [128]u8 = undefined;
    const opened = try encodePaneOpened_module(&payload, .{
        .request_id = @enumFromInt(4),
        .pane_id = @enumFromInt(30),
        .location = new_location,
        .created = true,
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(opened));

    try std.testing.expect(!client.notification_scheduler.pending);
    try std.testing.expectEqualDeep(
        @as(?WorkspaceLocationType, new_location.workspace),
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
    try std.testing.expectEqual(pending_updates_before_creation, host(client).presenter.pending_updates);
    try std.testing.expectEqual(@as(?PaneIdType, @enumFromInt(30)), support.reportedPaneId(client));

    const bookmark = client.navigation_history.find(prior_location.workspace).?;
    try std.testing.expectEqual(prior_location, bookmark.location);
    try std.testing.expectEqual(bottom_right, bookmark.pane_id);
    const saved_layout = bookmark.tab_layout.?;
    var saved_geometry: LayoutSnapshot = .{};
    saved_layout.snapshot(workbench, &saved_geometry);
    for ([_]PaneIdType{ left, top_right, bottom_right }) |pane_id|
        try std.testing.expectEqual(
            expected_geometry.find(pane_id).?.outer,
            saved_geometry.find(pane_id).?.outer,
        );

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates_before_creation + 1, host(client).presenter.pending_updates);
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const workspace_snapshot = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(workspace_snapshot == .request_workspace_snapshot);
    try std.testing.expectEqualDeep(new_location.workspace, workspace_snapshot.request_workspace_snapshot.workspace);
    const tab_snapshot = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(tab_snapshot == .request_tab_snapshot);
    try std.testing.expectEqualDeep(new_location, tab_snapshot.request_tab_snapshot.location);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);

    // Return through the same runtime handoff used by workspace selection.
    client.request_lifecycle.tracker = .{};
    _ = try workspace_handoffs.requestWorkspace(client, prior_location.workspace.workspace);
    try harness.settle();
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(@as(PaneIdType, @enumFromInt(30)), detached.detach_pane.pane_id);
    const open = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(open == .open_pane);
    try std.testing.expectEqualDeep(PaneTargetType{ .pane = bottom_right }, open.open_pane.target);
    const open_request = open.open_pane.request_id;

    const reopened = try encodePaneOpened_module(&payload, .{
        .request_id = open_request,
        .pane_id = bottom_right,
        .location = prior_location,
        .created = false,
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(reopened));
    try harness.settle();
    var snapshot_request: RequestIdType = .none;
    while (snapshot_request == .none) switch (try harness.nextClientMessage(&message_buffer)) {
        .request_workspace_snapshot => {},
        .request_tab_snapshot => |request| {
            try std.testing.expectEqual(prior_location, request.location);
            snapshot_request = request.request_id;
        },
        else => return error.UnexpectedClientMessage,
    };
    var snapshot_payload: [256]u8 = undefined;
    const snapshot = try encodeTabSnapshot_module(&snapshot_payload, .{
        .request_id = snapshot_request,
        .location = prior_location,
        .panes = &.{
            .{ .pane_id = left, .lifecycle = .running },
            .{ .pane_id = top_right, .lifecycle = .running },
            .{ .pane_id = bottom_right, .lifecycle = .running },
        },
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(snapshot));

    var restored_geometry: LayoutSnapshot = .{};
    client.model.workspace.activeConst().?.model.layout.snapshot(workbench, &restored_geometry);
    for ([_]PaneIdType{ left, top_right, bottom_right }) |pane_id|
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
    const failed = try encodeRequestFailed_module(&payload, .{
        .request_id = @enumFromInt(4),
        .code = .spawn_failed,
        .message = "shell launch failed",
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(failed));

    try support.expectOnlyNotificationVersionChanged(version_before_failure, client.model.version());
    try std.testing.expectEqualDeep(location_before_failure, client.model.activeTabLocation().?);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane) != null);
    try std.testing.expect(client.notification_scheduler.pending);
}
