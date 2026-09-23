//! Client integration tests for workspace lifecycle.

const core = @import("telar-core");
const data = @import("model");
const TerminalClient = @import("../TerminalClient.zig");
const TestHarness = @import("TestHarness.zig");
const std = @import("std");
const support = @import("support.zig");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const client_module = @import("telar-client");

test "a created workspace bookmarks and replaces the prior layout" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;

    const prior_location = TestHarness.bootstrap_location;
    const left = TestHarness.bootstrap_pane;
    const top_right: core.PaneId = @enumFromInt(11);
    const bottom_right: core.PaneId = @enumFromInt(12);
    const workbench = terminal.view.workbench();
    const prior_model = client.model.tabs.active;
    try data.pane_split.split(&client.model, prior_model, .{ .existing_pane = left, .new_pane = top_right, .location = prior_location, .axis = .horizontal, .area = workbench });
    try data.pane_split.split(&client.model, prior_model, .{ .existing_pane = top_right, .new_pane = bottom_right, .location = prior_location, .axis = .vertical, .area = workbench });
    client.model.panes.findIn(client.model.tabs.location[prior_model].tab_id, left).?.input_modes.focus_events = true;
    try std.testing.expect(client.model.tabs.layout[prior_model].focusPane(left));
    _ = client.model.syncReportedPaneFocus().?;
    try std.testing.expect(client.model.tabs.layout[prior_model].focusPane(bottom_right));
    var expected_geometry: data.LayoutSnapshot = .{};
    client.model.tabs.layout[prior_model].snapshot(workbench, &expected_geometry);

    const new_location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(5),
    };
    const version_before_creation = client.model.version();
    const pending_updates_before_creation = terminal.presenter.pending_updates;
    try client.model.request_lifecycle.tracker.add(@enumFromInt(4), .{ .create_workspace = .{ .cols = 80, .rows = 20 } });
    var payload: [128]u8 = undefined;
    const opened = try core.encodePaneOpened(&payload, .{
        .request_id = @enumFromInt(4),
        .pane_id = @enumFromInt(30),
        .location = new_location,
        .created = true,
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(opened));

    try std.testing.expect(!client.model.notification_scheduler.pending);
    try std.testing.expectEqualDeep(
        @as(?core.WorkspaceLocation, new_location.workspace),
        client.model.workspace,
    );
    const created_pane = client.model.panes.find(@enumFromInt(30)).?;
    try std.testing.expectEqual(@as(u16, 80), created_pane.buffer.w);
    try std.testing.expectEqual(@as(u16, 20), created_pane.buffer.h);
    try std.testing.expect(client.model.panes.find(TestHarness.bootstrap_pane) == null);
    try std.testing.expectEqual(version_before_creation.workspace + 1, client.model.version().workspace);
    try std.testing.expectEqual(version_before_creation.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_creation.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(version_before_creation.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_creation, terminal.presenter.pending_updates);
    try std.testing.expectEqual(@as(?core.PaneId, @enumFromInt(30)), support.reportedPaneId(client));

    const bookmark = client.model.navigation_history.find(prior_location.workspace).?;
    try std.testing.expectEqual(prior_location, bookmark.location);
    try std.testing.expectEqual(bottom_right, bookmark.pane_id);
    const saved_layout = bookmark.tab_layout.?;
    var saved_geometry: data.LayoutSnapshot = .{};
    saved_layout.snapshot(workbench, &saved_geometry);
    for ([_]core.PaneId{ left, top_right, bottom_right }) |pane_id|
        try std.testing.expectEqual(
            expected_geometry.find(pane_id).?.outer,
            saved_geometry.find(pane_id).?.outer,
        );

    try presentation_lifecycle.observe(terminal);
    try std.testing.expectEqual(pending_updates_before_creation + 1, terminal.presenter.pending_updates);
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const workspace_snapshot = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(workspace_snapshot == .request_workspace_snapshot);
    try std.testing.expectEqualDeep(new_location.workspace, workspace_snapshot.request_workspace_snapshot.workspace);
    const tab_snapshot = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(tab_snapshot == .request_tab_snapshot);
    try std.testing.expectEqualDeep(new_location, tab_snapshot.request_tab_snapshot.location);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), terminal.presenter.presentation_state.prepared.model);

    // Return through the same runtime handoff used by workspace selection.
    client.model.request_lifecycle.tracker = .{};
    _ = try client_module.workspace_handoff.requestWorkspace(client, prior_location.workspace.workspace);
    try harness.settle();
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(@as(core.PaneId, @enumFromInt(30)), detached.detach_pane.pane_id);
    const open = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(open == .open_pane);
    try std.testing.expectEqualDeep(core.PaneTarget{ .pane = bottom_right }, open.open_pane.target);
    const open_request = open.open_pane.request_id;

    const reopened = try core.encodePaneOpened(&payload, .{
        .request_id = open_request,
        .pane_id = bottom_right,
        .location = prior_location,
        .created = false,
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(reopened));
    try harness.settle();
    var snapshot_request: core.RequestId = .none;
    while (snapshot_request == .none) switch (try harness.nextClientMessage(&message_buffer)) {
        .request_workspace_snapshot => {},
        .request_tab_snapshot => |request| {
            try std.testing.expectEqual(prior_location, request.location);
            snapshot_request = request.request_id;
        },
        else => return error.UnexpectedClientMessage,
    };
    var snapshot_payload: [256]u8 = undefined;
    const snapshot = try core.encodeTabSnapshot(&snapshot_payload, .{
        .request_id = snapshot_request,
        .location = prior_location,
        .panes = &.{
            .{ .pane_id = left, .lifecycle = .running },
            .{ .pane_id = top_right, .lifecycle = .running },
            .{ .pane_id = bottom_right, .lifecycle = .running },
        },
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(snapshot));

    var restored_geometry: data.LayoutSnapshot = .{};
    client.model.tabs.layout[client.model.tabs.active].snapshot(workbench, &restored_geometry);
    for ([_]core.PaneId{ left, top_right, bottom_right }) |pane_id|
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
    client.model.request_lifecycle.tracker = .{};
    const version_before_failure = client.model.version();
    const location_before_failure = client.model.activeTabLocation().?;

    try client.model.request_lifecycle.tracker.add(@enumFromInt(4), .{ .create_workspace = .{ .cols = 80, .rows = 20 } });
    var payload: [256]u8 = undefined;
    const failed = try core.encodeRequestFailed(&payload, .{
        .request_id = @enumFromInt(4),
        .code = .spawn_failed,
        .message = "shell launch failed",
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(failed));

    try support.expectOnlyNotificationVersionChanged(version_before_failure, client.model.version());
    try std.testing.expectEqualDeep(location_before_failure, client.model.activeTabLocation().?);
    try std.testing.expect(client.model.panes.find(TestHarness.bootstrap_pane) != null);
    try std.testing.expect(client.model.notification_scheduler.pending);
}

test "workspace creation validates names before request ownership or projection mutation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    const version = client.model.version();
    const next_request = client.model.request_lifecycle.next_request_id;

    try std.testing.expectError(error.InvalidWorkspaceName, client_module.workspace_creation.requestWorkspaceCreation(
        client,
        .{
            .name = "",
        },
    ));
    try std.testing.expectError(error.InvalidWorkspaceName, client_module.workspace_creation.requestWorkspaceCreation(
        client,
        .{
            .name = "bad\nname",
        },
    ));
    try std.testing.expectError(error.InvalidUtf8, client_module.workspace_creation.requestWorkspaceCreation(
        client,
        .{
            .name = "\xff",
        },
    ));

    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(next_request, client.model.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "workspace creation outbox failure releases correlation and retains the current workspace" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    while (client.model.to_runtime.hasCapacity()) {
        try client.model.to_runtime.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const version = client.model.version();

    try std.testing.expectError(error.ClientOutboxFull, client_module.workspace_creation.requestWorkspaceCreation(
        client,
        .{
            .name = "agents",
        },
    ));

    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expect(client.model.panes.find(TestHarness.bootstrap_pane).?.attached);
}

test "canonical workspace replacement survives failure to deliver activation snapshots" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    try client.model.request_lifecycle.tracker.add(@enumFromInt(4), .{ .create_workspace = .{ .cols = 80, .rows = 20 } });
    while (client.model.to_runtime.hasCapacity()) {
        try client.model.to_runtime.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const location: core.TabLocation = .{ .workspace = .{ .workspace = @enumFromInt(2) }, .tab_id = @enumFromInt(5) };
    var payload: [128]u8 = undefined;
    const opened = try core.encodePaneOpened(&payload, .{
        .request_id = @enumFromInt(4),
        .pane_id = @enumFromInt(30),
        .location = location,
        .created = true,
    });

    try std.testing.expectError(error.ClientOutboxFull, client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(opened)));

    try std.testing.expectEqualDeep(location, client.model.activeTabLocation().?);
    try std.testing.expect(client.model.panes.find(@enumFromInt(30)).?.attached);
    try std.testing.expect(client.model.panes.find(TestHarness.bootstrap_pane) == null);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.navigation_history.find(TestHarness.bootstrap_location.workspace).?.location);
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedRequest, client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(opened)));
}
