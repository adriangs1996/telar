//! Client integration tests for tab lifecycle.

const TestHarness = @import("TestHarness.zig");
const TabCreatedType = @import("telar-core").TabCreated;
const std = @import("std");
const tab_creations = @import("../controllers/tabs/tab_creations.zig");
const RequestIdType = @import("telar-core").RequestId;
const VersionType = @import("telar-client").Version;
const TabLocationType = @import("telar-core").TabLocation;
const TerminalSizeType = @import("telar-core").TerminalSize;
const encodeTabCreated_module = @import("telar-core").encodeTabCreated;
const decodeServer_module = @import("telar-core").decodeServer;
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const encodeTabRenamed_module = @import("telar-core").encodeTabRenamed;
const server_messages = @import("../entrypoints/runtime_messages.zig");
const encodeTabMoved_module = @import("telar-core").encodeTabMoved;
const encodeTabClosed_module = @import("telar-core").encodeTabClosed;
const encodeRequestFailed_module = @import("telar-core").encodeRequestFailed;
const support = @import("support.zig");
const TabMovedType = @import("telar-core").TabMoved;
const tab_moves = @import("../controllers/tabs/tab_moves.zig");
const InputHandler = @import("../resources/InputHandler.zig");
const client_actions = @import("../controllers/input/actions.zig");
const TabMoveDirectionType = @import("telar-core").TabMoveDirection;
const ChangeType = @import("telar-client").Change;
const PaneIdType = @import("telar-core").PaneId;
const capacity_module = @import("telar-client").capacity;
const active_pane_resources = @import("../controllers/panes/active_pane_resources.zig");
const TabClosedType = @import("telar-core").TabClosed;
const tab_closures = @import("../controllers/tabs/tab_closures.zig");
const PaneTargetType = @import("telar-core").PaneTarget;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const encodeResyncRequired_module = @import("telar-core").encodeResyncRequired;

test "an unexpected tab creation is rejected without effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const request_count_before = client.request_lifecycle.tracker.count;
    const pending_updates_before = client.presenter.pending_updates;
    const created: TabCreatedType = .{
        .request_id = @enumFromInt(99),
        .location = .{
            .workspace = TestHarness.bootstrap_location.workspace,
            .tab_id = @enumFromInt(2),
        },
        .position = 1,
        .label = "second",
        .root_pane_id = @enumFromInt(20),
    };

    try std.testing.expectError(error.UnexpectedTabCreated, tab_creations.apply(client, created));

    try std.testing.expectEqual(request_count_before, client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "tab creation consumes an incompatible continuation before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: RequestIdType = @enumFromInt(4);
    try client.request_lifecycle.tracker.add(request_id, .notification);
    const created: TabCreatedType = .{
        .request_id = request_id,
        .location = .{
            .workspace = TestHarness.bootstrap_location.workspace,
            .tab_id = @enumFromInt(2),
        },
        .position = 1,
        .label = "second",
        .root_pane_id = @enumFromInt(20),
    };

    try std.testing.expectError(error.UnexpectedTabCreated, tab_creations.apply(client, created));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabCreated, tab_creations.apply(client, created));
    try std.testing.expectEqualDeep(VersionType{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "tab creation consumes a mismatched workspace before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: RequestIdType = @enumFromInt(4);
    try client.request_lifecycle.tracker.add(request_id, .{ .create_tab = .{
        .workspace = TestHarness.bootstrap_location.workspace,
        .size = .{ .cols = 80, .rows = 20 },
    } });
    const created: TabCreatedType = .{
        .request_id = request_id,
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(2) },
            .tab_id = @enumFromInt(2),
        },
        .position = 1,
        .label = "second",
        .root_pane_id = @enumFromInt(20),
    };

    try std.testing.expectError(error.UnexpectedTabCreated, tab_creations.apply(client, created));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(VersionType{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "tab lifecycle: created, renamed, moved, closed" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    try harness.allowTabSelection();
    const client = harness.client;
    const workspace = TestHarness.bootstrap_location.workspace;
    const second_location: TabLocationType = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    const requested_size: TerminalSizeType = .{
        .cols = client.view.workbench().w - 1,
        .rows = client.view.workbench().h - 1,
    };
    var payload: [256]u8 = undefined;

    // Created: the new tab becomes active and the old one detaches.
    const version_before_creation = client.model.version();
    const pending_updates_before_creation = client.presenter.pending_updates;
    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .create_tab = .{
        .workspace = workspace,
        .size = requested_size,
    } });
    const created = try encodeTabCreated_module(&payload, .{
        .request_id = @enumFromInt(4),
        .location = second_location,
        .position = 1,
        .label = "second",
        .root_pane_id = @enumFromInt(20),
    });
    const creation = try tab_creations.apply(client, (try decodeServer_module(created)).tab_created);
    @memset(&payload, 'x');

    try std.testing.expect(!client.notification_scheduler.pending);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, creation.previous);
    try std.testing.expectEqualDeep(second_location, creation.created);
    try std.testing.expectEqual(@as(usize, 2), client.model.workspace.count);
    try std.testing.expectEqual(second_location.tab_id, client.model.workspace.active().?.location.tab_id);
    try std.testing.expectEqualStrings("second", client.model.workspace.active().?.labelSlice());
    try std.testing.expectEqual(version_before_creation.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_creation.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before_creation, client.presenter.pending_updates);
    try std.testing.expect(!client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    const created_pane = client.model.workspace.findPane(@enumFromInt(20)).?;
    try std.testing.expect(created_pane.attached);
    try std.testing.expectEqual(requested_size.cols, created_pane.buffer.w);
    try std.testing.expectEqual(requested_size.rows, created_pane.buffer.h);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_creation + 1, client.presenter.pending_updates);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const detached = try harness.nextClientMessage(&buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, detached.detach_pane.pane_id);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presentation_state.prepared.model);

    // Renamed.
    const version_before_rename = client.model.version();
    const pending_updates_before_rename = client.presenter.pending_updates;
    try client.request_lifecycle.tracker.add(@enumFromInt(5), .{ .rename_tab = second_location });
    const renamed = try encodeTabRenamed_module(&payload, .{
        .request_id = @enumFromInt(5),
        .location = second_location,
        .label = "renamed",
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(renamed));
    try std.testing.expectEqualStrings(
        "renamed",
        client.model.workspace.find(second_location.tab_id).?.labelSlice(),
    );
    try std.testing.expectEqual(version_before_rename.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_rename.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before_rename, client.presenter.pending_updates);
    try std.testing.expect(!client.notification_scheduler.pending);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_rename + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presentation_state.prepared.model);

    // Moved to the front.
    try client.request_lifecycle.tracker.add(@enumFromInt(6), .{ .move_tab = second_location });
    const moved = try encodeTabMoved_module(&payload, .{
        .request_id = @enumFromInt(6),
        .location = second_location,
        .position = 0,
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(moved));
    try std.testing.expectEqual(@as(?usize, 0), client.model.workspace.indexOf(second_location.tab_id));

    // Requested close of the active tab: the semantic commit precedes
    // cleanup, and the presenter observes it independently.
    try client.graphics_store.applyImage(.{ .pane_id = @enumFromInt(20), .revision = 1, .image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgb,
        .width = 1,
        .height = 1,
        .byte_len = 3,
    } });
    try std.testing.expect(client.model.enterCopyMode());
    try std.testing.expect(client.graphics_store.hasPaneGraphics(@enumFromInt(20)));
    const version_before_close = client.model.version();
    const pending_updates_before_close = client.presenter.pending_updates;
    try client.request_lifecycle.tracker.add(@enumFromInt(7), .{ .close_tab = second_location });
    const closed = try encodeTabClosed_module(&payload, .{
        .request_id = @enumFromInt(7),
        .location = second_location,
        .workspace_closed = false,
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try server_messages.handleServerMessage(client, try decodeServer_module(closed)),
    );

    try std.testing.expectEqual(@as(usize, 1), client.model.workspace.count);
    try std.testing.expectEqual(
        TestHarness.bootstrap_location.tab_id,
        client.model.workspace.active().?.location.tab_id,
    );
    try std.testing.expectEqual(version_before_close.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_close.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before_close, client.presenter.pending_updates);
    try std.testing.expect(!client.graphics_store.hasPaneGraphics(@enumFromInt(20)));
    try std.testing.expect(!client.model.copyModeActive());

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_close + 1, client.presenter.pending_updates);
    try harness.settle();
    const survivor_snapshot = try harness.nextClientMessage(&buffer);
    try std.testing.expect(survivor_snapshot == .request_tab_snapshot);
    try std.testing.expectEqualDeep(
        TestHarness.bootstrap_location,
        survivor_snapshot.request_tab_snapshot.location,
    );
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presentation_state.prepared.model);

    // An unknown close request is rejected.
    const unexpected = try encodeTabClosed_module(&payload, .{
        .request_id = @enumFromInt(99),
        .location = second_location,
        .workspace_closed = false,
    });
    try std.testing.expectError(
        error.UnexpectedTabClosed,
        server_messages.handleServerMessage(client, try decodeServer_module(unexpected)),
    );
}

test "rejected tab creation leaves the active tab attached" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before_creation = client.model.version();
    const pending_updates_before_creation = client.presenter.pending_updates;
    const request_count_before_creation = client.request_lifecycle.tracker.count;
    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{
        .create_tab = .{
            .workspace = TestHarness.bootstrap_location.workspace,
            .size = .{ .cols = 80, .rows = 20 },
        },
    });
    var payload: [256]u8 = undefined;
    const duplicate = try encodeTabCreated_module(&payload, .{
        .request_id = @enumFromInt(4),
        .location = TestHarness.bootstrap_location,
        .position = 1,
        .label = "duplicate",
        .root_pane_id = @enumFromInt(20),
    });
    const response = (try decodeServer_module(duplicate)).tab_created;

    try std.testing.expectError(
        error.TabAlreadyExists,
        tab_creations.apply(client, response),
    );

    try std.testing.expectEqual(request_count_before_creation, client.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabCreated, tab_creations.apply(client, response));
    try std.testing.expectEqual(@as(usize, 1), client.model.workspace.count);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqualDeep(version_before_creation, client.model.version());
    try std.testing.expectEqual(pending_updates_before_creation, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "a failed tab creation preserves the current projection and notifies" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before_failure = client.model.version();
    const location_before_failure = client.model.activeTabLocation().?;
    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .create_tab = .{
        .workspace = TestHarness.bootstrap_location.workspace,
        .size = .{ .cols = 80, .rows = 20 },
    } });
    var payload: [256]u8 = undefined;
    const failed = try encodeRequestFailed_module(&payload, .{
        .request_id = @enumFromInt(4),
        .code = .spawn_failed,
        .message = "shell launch failed",
    });

    _ = try server_messages.handleServerMessage(client, try decodeServer_module(failed));

    try support.expectOnlyNotificationVersionChanged(version_before_failure, client.model.version());
    try std.testing.expectEqualDeep(location_before_failure, client.model.activeTabLocation().?);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expect(client.notification_scheduler.pending);
}

test "an unexpected tab move is rejected without effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    const moved: TabMovedType = .{
        .request_id = @enumFromInt(99),
        .location = TestHarness.bootstrap_location,
        .position = 0,
    };

    try std.testing.expectError(error.UnexpectedTabMoved, tab_moves.apply(client, moved));

    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(?usize, 0), client.model.workspace.indexOf(TestHarness.bootstrap_location.tab_id));
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "tab move consumes an incompatible continuation before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const request_id: RequestIdType = @enumFromInt(90);
    const version_before = client.model.version();
    try client.request_lifecycle.tracker.add(request_id, .notification);
    const moved: TabMovedType = .{
        .request_id = request_id,
        .location = TestHarness.bootstrap_location,
        .position = 0,
    };

    try std.testing.expectError(error.UnexpectedTabMoved, tab_moves.apply(client, moved));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabMoved, tab_moves.apply(client, moved));
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(@as(?usize, 0), client.model.workspace.indexOf(TestHarness.bootstrap_location.tab_id));
}

test "tab move consumes a canonical response rejected by the model" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const request_id: RequestIdType = @enumFromInt(90);
    const version_before = client.model.version();
    try client.request_lifecycle.tracker.add(request_id, .{ .move_tab = TestHarness.bootstrap_location });
    const moved: TabMovedType = .{
        .request_id = request_id,
        .location = TestHarness.bootstrap_location,
        .position = 1,
    };

    try std.testing.expectError(error.UnexpectedTabMoved, tab_moves.apply(client, moved));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabMoved, tab_moves.apply(client, moved));
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(@as(?usize, 0), client.model.workspace.indexOf(TestHarness.bootstrap_location.tab_id));
}

test "move tab waits for the canonical response and preserves active identity" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second = try harness.addTab(@enumFromInt(2), @enumFromInt(20));
    const version_before_request = client.model.version();
    const pending_updates_before_request = client.presenter.pending_updates;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .{ .move_tab = .previous });

    try std.testing.expectEqual(@as(?usize, 1), client.model.workspace.indexOf(second.tab_id));
    try std.testing.expectEqualDeep(version_before_request, client.model.version());
    try std.testing.expectEqual(pending_updates_before_request, client.presenter.pending_updates);
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(message == .move_tab);
    try std.testing.expectEqualDeep(second, message.move_tab.location);
    try std.testing.expectEqual(TabMoveDirectionType.previous, message.move_tab.direction);
    try std.testing.expectEqual(@as(?usize, 1), client.model.workspace.indexOf(second.tab_id));
    const continuation = client.request_lifecycle.tracker.take(message.move_tab.request_id).?;
    try std.testing.expect(continuation == .move_tab);
    try std.testing.expectEqualDeep(second, continuation.move_tab);
    try client.request_lifecycle.tracker.add(message.move_tab.request_id, continuation);

    try std.testing.expect(client.model.workspace.select(TestHarness.bootstrap_location.tab_id));
    const version_before_response = client.model.version();
    const pending_updates_before_response = client.presenter.pending_updates;
    var response_buffer: [256]u8 = undefined;
    const response = try encodeTabMoved_module(&response_buffer, .{
        .request_id = message.move_tab.request_id,
        .location = second,
        .position = 0,
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(response));

    try std.testing.expectEqual(@as(?usize, 0), client.model.workspace.indexOf(second.tab_id));
    try std.testing.expectEqual(TestHarness.bootstrap_location.tab_id, client.model.workspace.activeConst().?.location.tab_id);
    try std.testing.expectEqual(version_before_response.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_response.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before_response, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presentation_state.observed.model);
    try std.testing.expectEqual(pending_updates_before_response + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presentation_state.prepared.model);
}

test "pending tab operation suppresses a move request" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second = try harness.addTab(@enumFromInt(2), @enumFromInt(20));
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{ .rename_tab = second });
    const request_count = client.request_lifecycle.tracker.count;
    const next_request_id = client.request_lifecycle.next_request_id;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .{ .move_tab = .previous });

    try std.testing.expectEqual(request_count, client.request_lifecycle.tracker.count);
    try std.testing.expectEqual(next_request_id, client.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expectEqual(@as(?usize, 1), client.model.workspace.indexOf(second.tab_id));
}

test "canonical tab move at an edge does not advance or schedule the model" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .{ .move_tab = .previous });
    try harness.settle();

    var message_buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(message == .move_tab);
    const version_before_response = client.model.version();
    const pending_updates_before_response = client.presenter.pending_updates;

    var response_buffer: [256]u8 = undefined;
    const response = try encodeTabMoved_module(&response_buffer, .{
        .request_id = message.move_tab.request_id,
        .location = message.move_tab.location,
        .position = 0,
    });
    try std.testing.expectEqual(
        ChangeType.unchanged,
        try tab_moves.apply(client, (try decodeServer_module(response)).tab_moved),
    );
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(version_before_response, client.model.version());
    try std.testing.expectEqual(pending_updates_before_response, client.presenter.pending_updates);
    try std.testing.expect(!client.request_lifecycle.tracker.has(.tab_operation));
}

test "tab move response must match the requested identity" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second = try harness.addTab(@enumFromInt(2), @enumFromInt(20));
    const version_before_response = client.model.version();
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .{ .move_tab = .previous });
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&message_buffer);
    var response_buffer: [256]u8 = undefined;
    const response = try encodeTabMoved_module(&response_buffer, .{
        .request_id = message.move_tab.request_id,
        .location = TestHarness.bootstrap_location,
        .position = 0,
    });

    try std.testing.expectError(
        error.UnexpectedTabMoved,
        server_messages.handleServerMessage(client, try decodeServer_module(response)),
    );

    try std.testing.expectEqual(@as(?usize, 1), client.model.workspace.indexOf(second.tab_id));
    try std.testing.expectEqualDeep(version_before_response, client.model.version());
    try std.testing.expect(!client.request_lifecycle.tracker.has(.tab_operation));
}

test "a failed tab move preserves order and notifies" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second = try harness.addTab(@enumFromInt(2), @enumFromInt(20));
    const version_before_failure = client.model.version();
    const active_before_failure = client.model.activeTabLocation().?;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .{ .move_tab = .previous });
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&message_buffer);
    var response_buffer: [256]u8 = undefined;
    const response = try encodeRequestFailed_module(&response_buffer, .{
        .request_id = message.move_tab.request_id,
        .code = .tab_not_found,
        .message = "tab not found",
    });

    _ = try server_messages.handleServerMessage(client, try decodeServer_module(response));

    try std.testing.expectEqual(@as(?usize, 1), client.model.workspace.indexOf(second.tab_id));
    try std.testing.expectEqualDeep(active_before_failure, client.model.activeTabLocation().?);
    try support.expectOnlyNotificationVersionChanged(version_before_failure, client.model.version());
    try std.testing.expect(!client.request_lifecycle.tracker.has(.tab_operation));
    try std.testing.expect(client.notification_scheduler.pending);
}

test "select tab closes captured paste before detaching and requesting the target snapshot" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    try harness.allowTabSelection();
    const client = harness.client;
    client.model.workspace.findPane(TestHarness.bootstrap_pane).?.input_modes.bracketed_paste = true;
    var handler: InputHandler = .{ .client = client };
    try handler.pasteStart();
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const opening = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(opening == .pane_input);
    try std.testing.expectEqualStrings("\x1b[200~", opening.pane_input.bytes);
    const second_pane: PaneIdType = @enumFromInt(20);
    const second = try harness.addInactiveTab(@enumFromInt(2), second_pane);
    const version_before_selection = client.model.version();
    const pending_updates_before_selection = client.presenter.pending_updates;

    _ = try client_actions.apply(handler.client, .{ .select_tab = 1 });

    try std.testing.expectEqual(second, client.model.activeTabLocation().?);
    try std.testing.expectEqual(version_before_selection.tabs, client.model.version().tabs);
    try std.testing.expectEqual(version_before_selection.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before_selection, client.presenter.pending_updates);
    try std.testing.expect(!client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expect(!client.model.workspace.findPane(second_pane).?.attached);
    try std.testing.expect(!client.graphics_store.paneVisible(TestHarness.bootstrap_pane));
    try std.testing.expect(client.graphics_store.paneVisible(second_pane));
    try std.testing.expect(!client.model.panePasteActive());

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_selection + 1, client.presenter.pending_updates);
    try harness.settle();

    const closing = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(closing == .pane_input);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, closing.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x1b[201~", closing.pane_input.bytes);
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, detached.detach_pane.pane_id);
    const snapshot = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(snapshot == .request_tab_snapshot);
    try std.testing.expectEqualDeep(second, snapshot.request_tab_snapshot.location);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presentation_state.prepared.model);
}

test "tab selection offset wraps while full turns remain no-ops" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    try harness.allowTabSelection();
    const client = harness.client;
    const second = try harness.addInactiveTab(@enumFromInt(2), @enumFromInt(20));
    const version_before_selection = client.model.version();
    const request_id_before_selection = client.request_lifecycle.next_request_id;
    const pending_updates_before_selection = client.presenter.pending_updates;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .{ .select_tab_offset = 2 });

    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(version_before_selection, client.model.version());
    try std.testing.expectEqual(request_id_before_selection, client.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);

    _ = try client_actions.apply(handler.client, .{ .select_tab_offset = -1 });

    try std.testing.expectEqualDeep(second, client.model.activeTabLocation().?);
    try std.testing.expectEqual(version_before_selection.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(request_id_before_selection + 1, client.request_lifecycle.next_request_id);
    try std.testing.expect(client.request_lifecycle.tracker.has(.tab_snapshot));
    try std.testing.expectEqual(@as(usize, 2), client.runtime_transport.outbox.len);
    try std.testing.expectEqual(pending_updates_before_selection, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates_before_selection + 1, client.presenter.pending_updates);
}

test "pending tab snapshot suppresses tab selection without effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second_pane: PaneIdType = @enumFromInt(20);
    _ = try harness.addInactiveTab(@enumFromInt(2), second_pane);
    const version_before_selection = client.model.version();
    const next_request_id = client.request_lifecycle.next_request_id;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .{ .select_tab = 1 });

    try std.testing.expectEqual(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expect(!client.model.workspace.findPane(second_pane).?.attached);
    try std.testing.expectEqualDeep(version_before_selection, client.model.version());
    try std.testing.expectEqual(next_request_id, client.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "close tab request detaches before delivery and rejection requests restoration" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const version_before_request = client.model.version();
    const pending_updates_before_request = client.presenter.pending_updates;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .close_tab);

    try std.testing.expectEqualDeep(version_before_request, client.model.version());
    try std.testing.expectEqual(pending_updates_before_request, client.presenter.pending_updates);
    try std.testing.expect(!client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);

    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, detached.detach_pane.pane_id);
    const requested = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(requested == .close_tab);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, requested.close_tab.location);

    var failure_buffer: [256]u8 = undefined;
    const failed = try encodeRequestFailed_module(&failure_buffer, .{
        .request_id = requested.close_tab.request_id,
        .code = .internal,
        .message = "close rejected",
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(failed));
    try harness.settle();

    const recovery = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(recovery == .request_tab_snapshot);
    try std.testing.expectEqualDeep(
        TestHarness.bootstrap_location,
        recovery.request_tab_snapshot.location,
    );
    try std.testing.expect(client.notification_scheduler.pending);
    try support.expectOnlyNotificationVersionChanged(version_before_request, client.model.version());
}

test "close tab capacity failure preserves attachment and request state" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    while (client.runtime_transport.outbox.len < capacity_module - 1) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const version_before = client.model.version();
    const focus_before = client.model.reportedPaneFocus();
    const next_request_id = client.request_lifecycle.next_request_id;
    const handler: InputHandler = .{ .client = client };

    try std.testing.expectError(
        error.ClientOutboxFull,
        client_actions.apply(handler.client, .close_tab),
    );

    try std.testing.expectEqual(capacity_module - 1, @as(usize, client.runtime_transport.outbox.len));
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqualDeep(focus_before, client.model.reportedPaneFocus());
    try std.testing.expectEqual(next_request_id, client.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
}

test "close tab reserves its focus-out message" {
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
    while (client.runtime_transport.outbox.len < capacity_module - 2) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const version = client.model.version();
    const reported = client.model.reportedPaneFocus();
    const next_request_id = client.request_lifecycle.next_request_id;

    try std.testing.expectError(
        error.ClientOutboxFull,
        client_actions.apply(client, .close_tab),
    );

    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqualDeep(reported, client.model.reportedPaneFocus());
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqual(next_request_id, client.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
}

test "close tab reserves its captured paste closing marker" {
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
    while (client.runtime_transport.outbox.len < capacity_module - 2) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const version = client.model.version();
    const next_request_id = client.request_lifecycle.next_request_id;

    try std.testing.expectError(
        error.ClientOutboxFull,
        client_actions.apply(client, .close_tab),
    );

    try std.testing.expect(client.model.panePasteActive());
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqual(next_request_id, client.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version, client.model.version());
}

test "an unexpected tab closure is rejected without effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    const closed: TabClosedType = .{
        .request_id = @enumFromInt(99),
        .location = TestHarness.bootstrap_location,
        .workspace_closed = true,
    };

    try std.testing.expectError(error.UnexpectedTabClosed, tab_closures.apply(client, closed));

    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "tab closure consumes an incompatible continuation before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const request_id: RequestIdType = @enumFromInt(90);
    const version_before = client.model.version();
    try client.request_lifecycle.tracker.add(request_id, .notification);
    const closed: TabClosedType = .{
        .request_id = request_id,
        .location = TestHarness.bootstrap_location,
        .workspace_closed = true,
    };

    try std.testing.expectError(error.UnexpectedTabClosed, tab_closures.apply(client, closed));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabClosed, tab_closures.apply(client, closed));
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
}

test "tab close response must match the requested identity" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const second = try harness.addInactiveTab(@enumFromInt(2), @enumFromInt(20));
    const request_id: RequestIdType = @enumFromInt(7);
    try client.request_lifecycle.tracker.add(request_id, .{ .close_tab = TestHarness.bootstrap_location });
    const version_before = client.model.version();

    var payload: [128]u8 = undefined;
    const closed = try encodeTabClosed_module(&payload, .{
        .request_id = request_id,
        .location = second,
        .workspace_closed = false,
    });

    try std.testing.expectError(
        error.UnexpectedTabClosed,
        tab_closures.apply(client, (try decodeServer_module(closed)).tab_closed),
    );
    try std.testing.expectEqual(@as(usize, 2), client.model.workspace.count);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
}

test "late correlated close after lifecycle removal is ignored" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const second = try harness.addInactiveTab(@enumFromInt(2), @enumFromInt(20));
    const request_id: RequestIdType = @enumFromInt(7);
    try client.request_lifecycle.tracker.add(request_id, .{ .close_tab = second });

    var payload: [128]u8 = undefined;
    const lifecycle = try encodeTabClosed_module(&payload, .{
        .request_id = .none,
        .location = second,
        .workspace_closed = false,
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(lifecycle));
    const version_after_lifecycle = client.model.version();

    const response = try encodeTabClosed_module(&payload, .{
        .request_id = request_id,
        .location = second,
        .workspace_closed = false,
    });
    try std.testing.expectEqual(
        tab_closures.Outcome.ignored,
        try tab_closures.apply(client, (try decodeServer_module(response)).tab_closed),
    );

    try std.testing.expectEqual(@as(usize, 1), client.model.workspace.count);
    try std.testing.expectEqualDeep(version_after_lifecycle, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
}

test "inactive tab lifecycle closure changes only the tab collection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const second_pane: PaneIdType = @enumFromInt(20);
    const second = try harness.addInactiveTab(@enumFromInt(2), second_pane);
    try client.graphics_store.applyImage(.{ .pane_id = second_pane, .revision = 1, .image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgb,
        .width = 1,
        .height = 1,
        .byte_len = 3,
    } });
    const version_before_close = client.model.version();
    const pending_updates_before_close = client.presenter.pending_updates;

    var payload: [128]u8 = undefined;
    const closed = try encodeTabClosed_module(&payload, .{
        .request_id = .none,
        .location = second,
        .workspace_closed = false,
    });
    try std.testing.expectEqual(
        tab_closures.Outcome.applied,
        try tab_closures.apply(client, (try decodeServer_module(closed)).tab_closed),
    );

    try std.testing.expectEqual(@as(usize, 1), client.model.workspace.count);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqual(version_before_close.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_close.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before_close, client.presenter.pending_updates);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expect(!client.graphics_store.hasPaneGraphics(second_pane));
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_close + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presentation_state.prepared.model);
}

test "invalid last tab closure has no semantic or cleanup effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    try client.graphics_store.applyImage(.{ .pane_id = TestHarness.bootstrap_pane, .revision = 1, .image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgb,
        .width = 1,
        .height = 1,
        .byte_len = 3,
    } });
    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .close_tab = TestHarness.bootstrap_location });
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{ .tab_snapshot = TestHarness.bootstrap_location });
    const version_before_close = client.model.version();
    const pending_updates_before_close = client.presenter.pending_updates;

    var payload: [128]u8 = undefined;
    const closed = try encodeTabClosed_module(&payload, .{
        .request_id = @enumFromInt(4),
        .location = TestHarness.bootstrap_location,
        .workspace_closed = false,
    });
    try std.testing.expectError(
        error.UnexpectedWorkspaceRemoval,
        tab_closures.apply(client, (try decodeServer_module(closed)).tab_closed),
    );

    try std.testing.expectEqual(@as(usize, 1), client.request_lifecycle.tracker.count);
    try std.testing.expectError(
        error.UnexpectedTabClosed,
        tab_closures.apply(client, (try decodeServer_module(closed)).tab_closed),
    );
    try std.testing.expectEqual(@as(usize, 1), client.model.workspace.count);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expect(client.graphics_store.hasPaneGraphics(TestHarness.bootstrap_pane));
    try std.testing.expectEqualDeep(version_before_close, client.model.version());
    try std.testing.expectEqual(pending_updates_before_close, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expect(client.request_lifecycle.tracker.take(@enumFromInt(90)).? == .tab_snapshot);
}

test "closing the last workspace exits the client" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    try client.graphics_store.applyImage(.{ .pane_id = TestHarness.bootstrap_pane, .revision = 1, .image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgb,
        .width = 1,
        .height = 1,
        .byte_len = 3,
    } });
    const version_before_close = client.model.version();

    var payload: [128]u8 = undefined;
    const closed = try encodeTabClosed_module(&payload, .{
        .request_id = .none,
        .location = TestHarness.bootstrap_location,
        .workspace_closed = true,
    });
    try std.testing.expectEqual(
        @as(?u8, 0),
        try server_messages.handleServerMessage(client, try decodeServer_module(closed)),
    );
    try std.testing.expectEqual(@as(usize, 0), client.model.workspace.count);
    try std.testing.expect(client.model.activeTabLocation() == null);
    try std.testing.expectEqual(version_before_close.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_close.active_tab + 1, client.model.version().active_tab);
    try std.testing.expect(!client.graphics_store.hasPaneGraphics(TestHarness.bootstrap_pane));
    try std.testing.expectEqual(@as(?PaneIdType, null), support.reportedPaneId(client));
}

test "tab removal follows the runtime predecessor after its workspace disappears" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    client.navigation_history.remember(.{
        .location = TestHarness.bootstrap_location,
        .pane_id = TestHarness.bootstrap_pane,
    });
    const close_request_id: RequestIdType = @enumFromInt(7);
    try client.request_lifecycle.tracker.add(close_request_id, .{ .close_tab = TestHarness.bootstrap_location });

    var payload: [128]u8 = undefined;
    const closed = try encodeTabClosed_module(&payload, .{
        .request_id = .none,
        .location = TestHarness.bootstrap_location,
        .workspace_closed = true,
        .previous_workspace = @enumFromInt(2),
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try server_messages.handleServerMessage(client, try decodeServer_module(closed)),
    );

    try std.testing.expect(client.model.workspaceLocation() == null);
    try std.testing.expect(client.navigation_history.find(TestHarness.bootstrap_location.workspace) == null);
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .open_pane);
    try std.testing.expectEqualDeep(
        PaneTargetType{ .workspace = @enumFromInt(2) },
        message.open_pane.target,
    );
    const continuation = client.request_lifecycle.tracker.take(message.open_pane.request_id).?;
    try std.testing.expect(continuation == .initial_open);
    try std.testing.expectEqual(@as(?WorkspaceIdType, @enumFromInt(2)), continuation.initial_open.fallback_workspace);
    try std.testing.expect(client.request_lifecycle.tracker.take(close_request_id).? == .ignored);
}

test "resync follows the runtime predecessor after a workspace disappears" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.client.navigation_history.remember(.{
        .location = TestHarness.bootstrap_location,
        .pane_id = TestHarness.bootstrap_pane,
    });

    var payload: [128]u8 = undefined;
    const resync = try encodeResyncRequired_module(&payload, .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .workspace_closed = true,
        .previous_workspace = @enumFromInt(2),
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try server_messages.handleServerMessage(harness.client, try decodeServer_module(resync)),
    );
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .open_pane);
    try std.testing.expectEqualDeep(
        PaneTargetType{ .workspace = @enumFromInt(2) },
        message.open_pane.target,
    );
    try std.testing.expect(
        harness.client.navigation_history.find(TestHarness.bootstrap_location.workspace) == null,
    );
}

test "resync forgets the final workspace before exiting" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.navigation_history.remember(.{
        .location = TestHarness.bootstrap_location,
        .pane_id = TestHarness.bootstrap_pane,
    });
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;

    var payload: [128]u8 = undefined;
    const resync = try encodeResyncRequired_module(&payload, .{
        .workspace = TestHarness.bootstrap_location.workspace,
        .workspace_closed = true,
    });

    try std.testing.expectEqual(
        @as(?u8, 0),
        try server_messages.handleServerMessage(client, try decodeServer_module(resync)),
    );
    try std.testing.expect(
        client.navigation_history.find(TestHarness.bootstrap_location.workspace) == null,
    );
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
}
