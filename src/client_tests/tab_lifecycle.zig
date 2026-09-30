//! Client integration tests for tab lifecycle.

const core = @import("telar-core");
const client_module = @import("telar-client");
const data = @import("model");
const ClientHarness = @import("ClientHarness.zig");
const std = @import("std");
const fixtures = @import("fixtures.zig");

const max_image_panes = 4;

test "an unexpected tab creation is rejected without effects" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const request_count_before = client.model.request_lifecycle.tracker.count;
    const created: core.TabCreated = .{
        .request_id = @enumFromInt(99),
        .location = .{
            .workspace = ClientHarness.bootstrap_location.workspace,
            .tab_id = @enumFromInt(2),
        },
        .position = 1,
        .label = "second",
        .root_pane_id = @enumFromInt(20),
    };

    try std.testing.expectError(error.UnexpectedTabCreated, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .tab_created = created,
        },
    ));

    try std.testing.expectEqual(request_count_before, client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expect(!presentationPending(&harness));
    try std.testing.expect(client.model.panes.find(ClientHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "tab creation consumes an incompatible continuation before rejection" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: core.RequestId = @enumFromInt(4);
    try client.model.request_lifecycle.tracker.add(request_id, .notification);
    const created: core.TabCreated = .{
        .request_id = request_id,
        .location = .{
            .workspace = ClientHarness.bootstrap_location.workspace,
            .tab_id = @enumFromInt(2),
        },
        .position = 1,
        .label = "second",
        .root_pane_id = @enumFromInt(20),
    };

    try std.testing.expectError(error.UnexpectedTabCreated, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .tab_created = created,
        },
    ));
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabCreated, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .tab_created = created,
        },
    ));
    try std.testing.expectEqualDeep(data.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "tab creation consumes a mismatched workspace before rejection" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: core.RequestId = @enumFromInt(4);
    try client.model.request_lifecycle.tracker.add(request_id, .{ .create_tab = .{
        .workspace = ClientHarness.bootstrap_location.workspace,
        .size = .{ .cols = 80, .rows = 20 },
    } });
    const created: core.TabCreated = .{
        .request_id = request_id,
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(2) },
            .tab_id = @enumFromInt(2),
        },
        .position = 1,
        .label = "second",
        .root_pane_id = @enumFromInt(20),
    };

    try std.testing.expectError(error.UnexpectedTabCreated, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .tab_created = created,
        },
    ));
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(data.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "tab lifecycle: created, renamed, moved, closed" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    try harness.allowTabSelection();
    const client = harness.client;
    const workspace = ClientHarness.bootstrap_location.workspace;
    const second_location: core.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    const workbench = client.geometry().area;
    const requested_size: core.TerminalSize = .{
        .cols = workbench.w - 1,
        .rows = workbench.h - 1,
    };
    var payload: [256]u8 = undefined;

    // Created: the new tab becomes active and the old one detaches.
    const version_before_creation = client.model.version();
    try client.model.request_lifecycle.tracker.add(@enumFromInt(4), .{ .create_tab = .{
        .workspace = workspace,
        .size = requested_size,
    } });
    const created = try core.encodeTabCreated(&payload, .{
        .request_id = @enumFromInt(4),
        .location = second_location,
        .position = 1,
        .label = "second",
        .root_pane_id = @enumFromInt(20),
    });
    _ = try client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .tab_created = (try core.decodeServer(created)).tab_created,
        },
    );
    @memset(&payload, 'x');

    try std.testing.expect(!client.model.notification_scheduler.pending);
    try std.testing.expectEqualDeep(second_location, client.model.activeTabLocation().?);
    try std.testing.expectEqual(@as(usize, 2), client.model.tabs.count);
    try std.testing.expectEqual(second_location.tab_id, client.model.tabs.location[client.model.tabs.active].tab_id);
    try std.testing.expectEqualStrings("second", data.tab_label.text(&client.model, client.model.tabs.active));
    try std.testing.expectEqual(version_before_creation.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_creation.active_tab + 1, client.model.version().active_tab);
    try std.testing.expect(presentationPending(&harness));
    try std.testing.expect(!client.model.panes.find(ClientHarness.bootstrap_pane).?.attached);
    const created_pane = client.model.panes.find(@enumFromInt(20)).?;
    try std.testing.expect(created_pane.attached);
    try std.testing.expectEqual(requested_size.cols, created_pane.buffer.w);
    try std.testing.expectEqual(requested_size.rows, created_pane.buffer.h);

    try harness.settle();
    var buffer: [256]u8 = undefined;
    const detached = try harness.nextClientMessage(&buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, detached.detach_pane.pane_id);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);

    // Renamed.
    const version_before_rename = client.model.version();
    try client.model.request_lifecycle.tracker.add(@enumFromInt(5), .{ .rename_tab = second_location });
    const renamed = try core.encodeTabRenamed(&payload, .{
        .request_id = @enumFromInt(5),
        .location = second_location,
        .label = "renamed",
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(renamed));
    try std.testing.expectEqualStrings(
        "renamed",
        data.tab_label.text(&client.model, client.model.tabs.find(second_location.tab_id).?),
    );
    try std.testing.expectEqual(version_before_rename.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_rename.active_tab, client.model.version().active_tab);
    try std.testing.expect(presentationPending(&harness));
    try std.testing.expect(!client.model.notification_scheduler.pending);

    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);

    // Moved to the front.
    try client.model.request_lifecycle.tracker.add(@enumFromInt(6), .{ .move_tab = second_location });
    const moved = try core.encodeTabMoved(&payload, .{
        .request_id = @enumFromInt(6),
        .location = second_location,
        .position = 0,
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(moved));
    try std.testing.expectEqual(@as(?usize, 0), client.model.tabs.find(second_location.tab_id));

    // Requested close of the active tab: the semantic commit precedes
    // cleanup, and the presentation observes it independently.
    try retainImage(client, @enumFromInt(20));
    try std.testing.expect(data.copy_mode.enter(&client.model));
    try std.testing.expect(client.graphics.hasPaneGraphics(@enumFromInt(20)));
    try harness.settleModelPresentation();
    const version_before_close = client.model.version();
    try client.model.request_lifecycle.tracker.add(@enumFromInt(7), .{ .close_tab = second_location });
    const closed = try core.encodeTabClosed(&payload, .{
        .request_id = @enumFromInt(7),
        .location = second_location,
        .workspace_closed = false,
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(closed)),
    );

    try std.testing.expectEqual(@as(usize, 1), client.model.tabs.count);
    try std.testing.expectEqual(
        ClientHarness.bootstrap_location.tab_id,
        client.model.tabs.location[client.model.tabs.active].tab_id,
    );
    try std.testing.expectEqual(version_before_close.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_close.active_tab + 1, client.model.version().active_tab);
    try std.testing.expect(presentationPending(&harness));
    try std.testing.expect(!client.graphics.hasPaneGraphics(@enumFromInt(20)));
    try std.testing.expect(!data.copy_mode.isActive(&client.model));

    try harness.settle();
    const survivor_snapshot = try harness.nextClientMessage(&buffer);
    try std.testing.expect(survivor_snapshot == .request_tab_snapshot);
    try std.testing.expectEqualDeep(
        ClientHarness.bootstrap_location,
        survivor_snapshot.request_tab_snapshot.location,
    );
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);

    // An unknown close request is rejected.
    const unexpected = try core.encodeTabClosed(&payload, .{
        .request_id = @enumFromInt(99),
        .location = second_location,
        .workspace_closed = false,
    });
    try std.testing.expectError(
        error.UnexpectedTabClosed,
        client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(unexpected)),
    );
}

test "rejected tab creation leaves the active tab attached" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before_creation = client.model.version();
    const request_count_before_creation = client.model.request_lifecycle.tracker.count;
    try client.model.request_lifecycle.tracker.add(@enumFromInt(4), .{
        .create_tab = .{
            .workspace = ClientHarness.bootstrap_location.workspace,
            .size = .{ .cols = 80, .rows = 20 },
        },
    });
    var payload: [256]u8 = undefined;
    const duplicate = try core.encodeTabCreated(&payload, .{
        .request_id = @enumFromInt(4),
        .location = ClientHarness.bootstrap_location,
        .position = 1,
        .label = "duplicate",
        .root_pane_id = @enumFromInt(20),
    });
    const response = (try core.decodeServer(duplicate)).tab_created;

    try std.testing.expectError(
        error.TabAlreadyExists,
        client_module.runtime_messages.handleServerMessage(
            client,
            .{
                .tab_created = response,
            },
        ),
    );

    try std.testing.expectEqual(request_count_before_creation, client.model.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabCreated, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .tab_created = response,
        },
    ));
    try std.testing.expectEqual(@as(usize, 1), client.model.tabs.count);
    try std.testing.expectEqualDeep(ClientHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expect(client.model.panes.find(ClientHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqualDeep(version_before_creation, client.model.version());
    try std.testing.expect(!presentationPending(&harness));
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "a failed tab creation preserves the current projection and notifies" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before_failure = client.model.version();
    const location_before_failure = client.model.activeTabLocation().?;
    try client.model.request_lifecycle.tracker.add(@enumFromInt(4), .{ .create_tab = .{
        .workspace = ClientHarness.bootstrap_location.workspace,
        .size = .{ .cols = 80, .rows = 20 },
    } });
    var payload: [256]u8 = undefined;
    const failed = try core.encodeRequestFailed(&payload, .{
        .request_id = @enumFromInt(4),
        .code = .spawn_failed,
        .message = "shell launch failed",
    });

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(failed));

    try fixtures.expectOnlyNotificationVersionChanged(version_before_failure, client.model.version());
    try std.testing.expectEqualDeep(location_before_failure, client.model.activeTabLocation().?);
    try std.testing.expect(client.model.panes.find(ClientHarness.bootstrap_pane).?.attached);
    try std.testing.expect(client.model.notification_scheduler.pending);
}

test "an unexpected tab move is rejected without effects" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    const version_before = client.model.version();
    const moved: core.TabMoved = .{
        .request_id = @enumFromInt(99),
        .location = ClientHarness.bootstrap_location,
        .position = 0,
    };

    try std.testing.expectError(error.UnexpectedTabMoved, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .tab_moved = moved,
        },
    ));

    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expect(!presentationPending(&harness));
    try std.testing.expectEqual(@as(?usize, 0), client.model.tabs.find(ClientHarness.bootstrap_location.tab_id));
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "tab move consumes an incompatible continuation before rejection" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    const request_id: core.RequestId = @enumFromInt(90);
    const version_before = client.model.version();
    try client.model.request_lifecycle.tracker.add(request_id, .notification);
    const moved: core.TabMoved = .{
        .request_id = request_id,
        .location = ClientHarness.bootstrap_location,
        .position = 0,
    };

    try std.testing.expectError(error.UnexpectedTabMoved, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .tab_moved = moved,
        },
    ));
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabMoved, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .tab_moved = moved,
        },
    ));
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(@as(?usize, 0), client.model.tabs.find(ClientHarness.bootstrap_location.tab_id));
}

test "tab move consumes a canonical response rejected by the model" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    const request_id: core.RequestId = @enumFromInt(90);
    const version_before = client.model.version();
    try client.model.request_lifecycle.tracker.add(request_id, .{ .move_tab = ClientHarness.bootstrap_location });
    const moved: core.TabMoved = .{
        .request_id = request_id,
        .location = ClientHarness.bootstrap_location,
        .position = 1,
    };

    try std.testing.expectError(error.UnexpectedTabMoved, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .tab_moved = moved,
        },
    ));
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabMoved, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .tab_moved = moved,
        },
    ));
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(@as(?usize, 0), client.model.tabs.find(ClientHarness.bootstrap_location.tab_id));
}

test "move tab waits for the canonical response and preserves active identity" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second = try harness.addTab(@enumFromInt(2), @enumFromInt(20));
    try harness.settleModelPresentation();
    const version_before_request = client.model.version();

    _ = try client_module.actions.executeAction(
        client,
        .{
            .move_tab = .previous,
        },
        .effect,
    );

    try std.testing.expectEqual(@as(?usize, 1), client.model.tabs.find(second.tab_id));
    try std.testing.expectEqualDeep(version_before_request, client.model.version());
    try std.testing.expect(!presentationPending(&harness));
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(message == .move_tab);
    try std.testing.expectEqualDeep(second, message.move_tab.location);
    try std.testing.expectEqual(core.TabMoveDirection.previous, message.move_tab.direction);
    try std.testing.expectEqual(@as(?usize, 1), client.model.tabs.find(second.tab_id));
    const continuation = client.model.request_lifecycle.tracker.take(message.move_tab.request_id).?;
    try std.testing.expect(continuation == .move_tab);
    try std.testing.expectEqualDeep(second, continuation.move_tab);
    try client.model.request_lifecycle.tracker.add(message.move_tab.request_id, continuation);

    try std.testing.expect(data.tab_selection.select(&client.model, ClientHarness.bootstrap_location.tab_id));
    try harness.settleModelPresentation();
    const version_before_response = client.model.version();
    var response_buffer: [256]u8 = undefined;
    const response = try core.encodeTabMoved(&response_buffer, .{
        .request_id = message.move_tab.request_id,
        .location = second,
        .position = 0,
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(response));

    try std.testing.expectEqual(@as(?usize, 0), client.model.tabs.find(second.tab_id));
    try std.testing.expectEqual(ClientHarness.bootstrap_location.tab_id, client.model.tabs.location[client.model.tabs.active].tab_id);
    try std.testing.expectEqual(version_before_response.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_response.active_tab, client.model.version().active_tab);
    try std.testing.expect(presentationPending(&harness));

    try harness.present();

    try std.testing.expectEqualDeep(client.model.version(), client.presentation.observed.model);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);
}

test "pending tab operation suppresses a move request" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second = try harness.addTab(@enumFromInt(2), @enumFromInt(20));
    try client.model.request_lifecycle.tracker.add(@enumFromInt(90), .{ .rename_tab = second });
    const request_count = client.model.request_lifecycle.tracker.count;
    const next_request_id = client.model.request_lifecycle.next_request_id;

    _ = try client_module.actions.executeAction(
        client,
        .{
            .move_tab = .previous,
        },
        .effect,
    );

    try std.testing.expectEqual(request_count, client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqual(next_request_id, client.model.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
    try std.testing.expectEqual(@as(?usize, 1), client.model.tabs.find(second.tab_id));
}

test "canonical tab move at an edge does not advance or schedule the model" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    _ = try client_module.actions.executeAction(
        client,
        .{
            .move_tab = .previous,
        },
        .effect,
    );
    try harness.settle();

    var message_buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(message == .move_tab);
    const version_before_response = client.model.version();
    const prepared_before_response = client.presentation.prepared;

    var response_buffer: [256]u8 = undefined;
    const response = try core.encodeTabMoved(&response_buffer, .{
        .request_id = message.move_tab.request_id,
        .location = message.move_tab.location,
        .position = 0,
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try client_module.runtime_messages.handleServerMessage(
            client,
            .{
                .tab_moved = (try core.decodeServer(response)).tab_moved,
            },
        ),
    );
    try harness.present();

    try std.testing.expectEqualDeep(version_before_response, client.model.version());
    try std.testing.expectEqualDeep(prepared_before_response, client.presentation.prepared);
    try std.testing.expect(!client.model.request_lifecycle.tracker.has(.tab_operation));
}

test "tab move response must match the requested identity" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second = try harness.addTab(@enumFromInt(2), @enumFromInt(20));
    const version_before_response = client.model.version();

    _ = try client_module.actions.executeAction(
        client,
        .{
            .move_tab = .previous,
        },
        .effect,
    );
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&message_buffer);
    var response_buffer: [256]u8 = undefined;
    const response = try core.encodeTabMoved(&response_buffer, .{
        .request_id = message.move_tab.request_id,
        .location = ClientHarness.bootstrap_location,
        .position = 0,
    });

    try std.testing.expectError(
        error.UnexpectedTabMoved,
        client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(response)),
    );

    try std.testing.expectEqual(@as(?usize, 1), client.model.tabs.find(second.tab_id));
    try std.testing.expectEqualDeep(version_before_response, client.model.version());
    try std.testing.expect(!client.model.request_lifecycle.tracker.has(.tab_operation));
}

test "a failed tab move preserves order and notifies" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second = try harness.addTab(@enumFromInt(2), @enumFromInt(20));
    const version_before_failure = client.model.version();
    const active_before_failure = client.model.activeTabLocation().?;

    _ = try client_module.actions.executeAction(
        client,
        .{
            .move_tab = .previous,
        },
        .effect,
    );
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&message_buffer);
    var response_buffer: [256]u8 = undefined;
    const response = try core.encodeRequestFailed(&response_buffer, .{
        .request_id = message.move_tab.request_id,
        .code = .tab_not_found,
        .message = "tab not found",
    });

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(response));

    try std.testing.expectEqual(@as(?usize, 1), client.model.tabs.find(second.tab_id));
    try std.testing.expectEqualDeep(active_before_failure, client.model.activeTabLocation().?);
    try fixtures.expectOnlyNotificationVersionChanged(version_before_failure, client.model.version());
    try std.testing.expect(!client.model.request_lifecycle.tracker.has(.tab_operation));
    try std.testing.expect(client.model.notification_scheduler.pending);
}

test "select tab closes captured paste before detaching and requesting the target snapshot" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    try harness.allowTabSelection();
    const client = harness.client;
    client.model.panes.find(ClientHarness.bootstrap_pane).?.input_modes.bracketed_paste = true;
    _ = try client_module.paste_routing.start(client);
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const opening = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(opening == .pane_input);
    try std.testing.expectEqualStrings("\x1b[200~", opening.pane_input.bytes);
    const second_pane: core.PaneId = @enumFromInt(20);
    const second = try harness.addInactiveTab(@enumFromInt(2), second_pane);
    try harness.settleModelPresentation();
    const version_before_selection = client.model.version();

    _ = try client_module.actions.executeAction(
        client,
        .{
            .select_tab = 1,
        },
        .effect,
    );

    try std.testing.expectEqual(second, client.model.activeTabLocation().?);
    try std.testing.expectEqual(version_before_selection.tabs, client.model.version().tabs);
    try std.testing.expectEqual(version_before_selection.active_tab + 1, client.model.version().active_tab);
    try std.testing.expect(presentationPending(&harness));
    try std.testing.expect(!client.model.panes.find(ClientHarness.bootstrap_pane).?.attached);
    try std.testing.expect(!client.model.panes.find(second_pane).?.attached);
    try std.testing.expect(!client.graphics.paneVisible(ClientHarness.bootstrap_pane));
    try std.testing.expect(client.graphics.paneVisible(second_pane));
    try std.testing.expect(!data.pane_input.pasteActive(&client.model));

    try harness.settle();

    const closing = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(closing == .pane_input);
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, closing.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x1b[201~", closing.pane_input.bytes);
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, detached.detach_pane.pane_id);
    const snapshot = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(snapshot == .request_tab_snapshot);
    try std.testing.expectEqualDeep(second, snapshot.request_tab_snapshot.location);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);
}

test "tab selection offset wraps while full turns remain no-ops" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    try harness.allowTabSelection();
    const client = harness.client;
    const second = try harness.addInactiveTab(@enumFromInt(2), @enumFromInt(20));
    try harness.settleModelPresentation();
    const version_before_selection = client.model.version();
    const request_id_before_selection = client.model.request_lifecycle.next_request_id;

    _ = try client_module.actions.executeAction(
        client,
        .{
            .select_tab_offset = 2,
        },
        .effect,
    );

    try std.testing.expectEqualDeep(ClientHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(version_before_selection, client.model.version());
    try std.testing.expectEqual(request_id_before_selection, client.model.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);

    _ = try client_module.actions.executeAction(
        client,
        .{
            .select_tab_offset = -1,
        },
        .effect,
    );

    try std.testing.expectEqualDeep(second, client.model.activeTabLocation().?);
    try std.testing.expectEqual(version_before_selection.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(request_id_before_selection + 1, client.model.request_lifecycle.next_request_id);
    try std.testing.expect(client.model.request_lifecycle.tracker.has(.tab_snapshot));
    try std.testing.expectEqual(@as(usize, 2), client.model.to_runtime.len);
    try std.testing.expect(presentationPending(&harness));
}

test "pending tab snapshot suppresses tab selection without effects" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second_pane: core.PaneId = @enumFromInt(20);
    _ = try harness.addInactiveTab(@enumFromInt(2), second_pane);
    const version_before_selection = client.model.version();
    const next_request_id = client.model.request_lifecycle.next_request_id;

    _ = try client_module.actions.executeAction(
        client,
        .{
            .select_tab = 1,
        },
        .effect,
    );

    try std.testing.expectEqual(ClientHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expect(client.model.panes.find(ClientHarness.bootstrap_pane).?.attached);
    try std.testing.expect(!client.model.panes.find(second_pane).?.attached);
    try std.testing.expectEqualDeep(version_before_selection, client.model.version());
    try std.testing.expectEqual(next_request_id, client.model.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "close tab request detaches before delivery and rejection requests restoration" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    const version_before_request = client.model.version();

    _ = try client_module.actions.executeAction(client, .close_tab, .effect);

    try std.testing.expectEqualDeep(version_before_request, client.model.version());
    try std.testing.expect(!presentationPending(&harness));
    try std.testing.expect(!client.model.panes.find(ClientHarness.bootstrap_pane).?.attached);

    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, detached.detach_pane.pane_id);
    const requested = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(requested == .close_tab);
    try std.testing.expectEqualDeep(ClientHarness.bootstrap_location, requested.close_tab.location);

    var failure_buffer: [256]u8 = undefined;
    const failed = try core.encodeRequestFailed(&failure_buffer, .{
        .request_id = requested.close_tab.request_id,
        .code = .internal,
        .message = "close rejected",
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(failed));
    try harness.settle();

    const recovery = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(recovery == .request_tab_snapshot);
    try std.testing.expectEqualDeep(
        ClientHarness.bootstrap_location,
        recovery.request_tab_snapshot.location,
    );
    try std.testing.expect(client.model.notification_scheduler.pending);
    try fixtures.expectOnlyNotificationVersionChanged(version_before_request, client.model.version());
}

test "close tab capacity failure preserves attachment and request state" {
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
        client_module.actions.executeAction(client, .close_tab, .effect),
    );

    try std.testing.expectEqual(data.outbox_support.capacity - 1, @as(usize, client.model.to_runtime.len));
    try std.testing.expect(client.model.panes.find(ClientHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqualDeep(focus_before, client.model.reported_pane_focus);
    try std.testing.expectEqual(next_request_id, client.model.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
}

test "close tab reserves its focus-out message" {
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
    const next_request_id = client.model.request_lifecycle.next_request_id;

    try std.testing.expectError(
        error.ClientOutboxFull,
        client_module.actions.executeAction(client, .close_tab, .effect),
    );

    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqualDeep(reported, client.model.reported_pane_focus);
    try std.testing.expect(client.model.panes.find(ClientHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqual(next_request_id, client.model.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
}

test "close tab reserves its captured paste closing marker" {
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
    const next_request_id = client.model.request_lifecycle.next_request_id;

    try std.testing.expectError(
        error.ClientOutboxFull,
        client_module.actions.executeAction(client, .close_tab, .effect),
    );

    try std.testing.expect(data.pane_input.pasteActive(&client.model));
    try std.testing.expect(client.model.panes.find(ClientHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqual(next_request_id, client.model.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version, client.model.version());
}

test "an unexpected tab closure is rejected without effects" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    const version_before = client.model.version();
    const closed: core.TabClosed = .{
        .request_id = @enumFromInt(99),
        .location = ClientHarness.bootstrap_location,
        .workspace_closed = true,
    };

    try std.testing.expectError(error.UnexpectedTabClosed, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .tab_closed = closed,
        },
    ));

    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expect(!presentationPending(&harness));
    try std.testing.expect(client.model.panes.find(ClientHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "tab closure consumes an incompatible continuation before rejection" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    const request_id: core.RequestId = @enumFromInt(90);
    const version_before = client.model.version();
    try client.model.request_lifecycle.tracker.add(request_id, .notification);
    const closed: core.TabClosed = .{
        .request_id = request_id,
        .location = ClientHarness.bootstrap_location,
        .workspace_closed = true,
    };

    try std.testing.expectError(error.UnexpectedTabClosed, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .tab_closed = closed,
        },
    ));
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabClosed, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .tab_closed = closed,
        },
    ));
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expect(client.model.panes.find(ClientHarness.bootstrap_pane).?.attached);
}

test "tab close response must match the requested identity" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    const second = try harness.addInactiveTab(@enumFromInt(2), @enumFromInt(20));
    const request_id: core.RequestId = @enumFromInt(7);
    try client.model.request_lifecycle.tracker.add(request_id, .{ .close_tab = ClientHarness.bootstrap_location });
    const version_before = client.model.version();

    var payload: [128]u8 = undefined;
    const closed = try core.encodeTabClosed(&payload, .{
        .request_id = request_id,
        .location = second,
        .workspace_closed = false,
    });

    try std.testing.expectError(
        error.UnexpectedTabClosed,
        client_module.runtime_messages.handleServerMessage(
            client,
            .{
                .tab_closed = (try core.decodeServer(closed)).tab_closed,
            },
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), client.model.tabs.count);
    try std.testing.expectEqualDeep(ClientHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
}

test "late correlated close after lifecycle removal is ignored" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    const second = try harness.addInactiveTab(@enumFromInt(2), @enumFromInt(20));
    const request_id: core.RequestId = @enumFromInt(7);
    try client.model.request_lifecycle.tracker.add(request_id, .{ .close_tab = second });

    var payload: [128]u8 = undefined;
    const lifecycle = try core.encodeTabClosed(&payload, .{
        .request_id = .none,
        .location = second,
        .workspace_closed = false,
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(lifecycle));
    const version_after_lifecycle = client.model.version();

    const response = try core.encodeTabClosed(&payload, .{
        .request_id = request_id,
        .location = second,
        .workspace_closed = false,
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try client_module.runtime_messages.handleServerMessage(
            client,
            .{
                .tab_closed = (try core.decodeServer(response)).tab_closed,
            },
        ),
    );

    try std.testing.expectEqual(@as(usize, 1), client.model.tabs.count);
    try std.testing.expectEqualDeep(version_after_lifecycle, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
}

test "inactive tab lifecycle closure changes only the tab collection" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    const second_pane: core.PaneId = @enumFromInt(20);
    const second = try harness.addInactiveTab(@enumFromInt(2), second_pane);
    try retainImage(client, second_pane);
    try harness.settleModelPresentation();
    const version_before_close = client.model.version();

    var payload: [128]u8 = undefined;
    const closed = try core.encodeTabClosed(&payload, .{
        .request_id = .none,
        .location = second,
        .workspace_closed = false,
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try client_module.runtime_messages.handleServerMessage(
            client,
            .{
                .tab_closed = (try core.decodeServer(closed)).tab_closed,
            },
        ),
    );

    try std.testing.expectEqual(@as(usize, 1), client.model.tabs.count);
    try std.testing.expectEqualDeep(ClientHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqual(version_before_close.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_close.active_tab, client.model.version().active_tab);
    try std.testing.expect(presentationPending(&harness));
    try std.testing.expect(client.model.panes.find(ClientHarness.bootstrap_pane).?.attached);
    try std.testing.expect(!client.graphics.hasPaneGraphics(second_pane));
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);

    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);
}

test "invalid last tab closure has no semantic or cleanup effects" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    try retainImage(client, ClientHarness.bootstrap_pane);
    try client.model.request_lifecycle.tracker.add(@enumFromInt(4), .{ .close_tab = ClientHarness.bootstrap_location });
    try client.model.request_lifecycle.tracker.add(@enumFromInt(90), .{ .tab_snapshot = ClientHarness.bootstrap_location });
    const version_before_close = client.model.version();

    var payload: [128]u8 = undefined;
    const closed = try core.encodeTabClosed(&payload, .{
        .request_id = @enumFromInt(4),
        .location = ClientHarness.bootstrap_location,
        .workspace_closed = false,
    });
    try std.testing.expectError(
        error.UnexpectedWorkspaceRemoval,
        client_module.runtime_messages.handleServerMessage(
            client,
            .{
                .tab_closed = (try core.decodeServer(closed)).tab_closed,
            },
        ),
    );

    try std.testing.expectEqual(@as(usize, 1), client.model.request_lifecycle.tracker.count);
    try std.testing.expectError(
        error.UnexpectedTabClosed,
        client_module.runtime_messages.handleServerMessage(
            client,
            .{
                .tab_closed = (try core.decodeServer(closed)).tab_closed,
            },
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), client.model.tabs.count);
    try std.testing.expectEqualDeep(ClientHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expect(client.model.panes.find(ClientHarness.bootstrap_pane).?.attached);
    try std.testing.expect(client.graphics.hasPaneGraphics(ClientHarness.bootstrap_pane));
    try std.testing.expectEqualDeep(version_before_close, client.model.version());
    try std.testing.expect(!presentationPending(&harness));
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
    try std.testing.expect(client.model.request_lifecycle.tracker.take(@enumFromInt(90)).? == .tab_snapshot);
}

test "closing the last workspace exits the client" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    try retainImage(client, ClientHarness.bootstrap_pane);
    const version_before_close = client.model.version();

    var payload: [128]u8 = undefined;
    const closed = try core.encodeTabClosed(&payload, .{
        .request_id = .none,
        .location = ClientHarness.bootstrap_location,
        .workspace_closed = true,
    });
    try std.testing.expectEqual(
        @as(?u8, 0),
        try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(closed)),
    );
    try std.testing.expectEqual(@as(usize, 0), client.model.tabs.count);
    try std.testing.expect(client.model.activeTabLocation() == null);
    try std.testing.expectEqual(version_before_close.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_close.active_tab + 1, client.model.version().active_tab);
    try std.testing.expect(!client.graphics.hasPaneGraphics(ClientHarness.bootstrap_pane));
    try std.testing.expectEqual(@as(?core.PaneId, null), fixtures.reportedPaneId(client));
}

test "tab removal follows the runtime predecessor after its workspace disappears" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    client.model.navigation_history.remember(.{
        .location = ClientHarness.bootstrap_location,
        .pane_id = ClientHarness.bootstrap_pane,
    });
    const close_request_id: core.RequestId = @enumFromInt(7);
    try client.model.request_lifecycle.tracker.add(close_request_id, .{ .close_tab = ClientHarness.bootstrap_location });

    var payload: [128]u8 = undefined;
    const closed = try core.encodeTabClosed(&payload, .{
        .request_id = .none,
        .location = ClientHarness.bootstrap_location,
        .workspace_closed = true,
        .previous_workspace = @enumFromInt(2),
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(closed)),
    );

    try std.testing.expect(client.model.workspace == null);
    try std.testing.expect(client.model.navigation_history.find(ClientHarness.bootstrap_location.workspace) == null);
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .open_pane);
    try std.testing.expectEqualDeep(
        core.PaneTarget{ .workspace = @enumFromInt(2) },
        message.open_pane.target,
    );
    const continuation = client.model.request_lifecycle.tracker.take(message.open_pane.request_id).?;
    try std.testing.expect(continuation == .initial_open);
    try std.testing.expectEqual(@as(?core.WorkspaceId, @enumFromInt(2)), continuation.initial_open.fallback_workspace);
    try std.testing.expect(client.model.request_lifecycle.tracker.take(close_request_id).? == .ignored);
}

test "resync follows the runtime predecessor after a workspace disappears" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.client.model.navigation_history.remember(.{
        .location = ClientHarness.bootstrap_location,
        .pane_id = ClientHarness.bootstrap_pane,
    });

    var payload: [128]u8 = undefined;
    const resync = try core.encodeResyncRequired(&payload, .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .workspace_closed = true,
        .previous_workspace = @enumFromInt(2),
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try client_module.runtime_messages.handleServerMessage(harness.client, try core.decodeServer(resync)),
    );
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .open_pane);
    try std.testing.expectEqualDeep(
        core.PaneTarget{ .workspace = @enumFromInt(2) },
        message.open_pane.target,
    );
    try std.testing.expect(
        harness.client.model.navigation_history.find(ClientHarness.bootstrap_location.workspace) == null,
    );
}

test "resync forgets the final workspace before exiting" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.model.navigation_history.remember(.{
        .location = ClientHarness.bootstrap_location,
        .pane_id = ClientHarness.bootstrap_pane,
    });
    const version_before = client.model.version();

    var payload: [128]u8 = undefined;
    const resync = try core.encodeResyncRequired(&payload, .{
        .workspace = ClientHarness.bootstrap_location.workspace,
        .workspace_closed = true,
    });

    try std.testing.expectEqual(
        @as(?u8, 0),
        try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(resync)),
    );
    try std.testing.expect(
        client.model.navigation_history.find(ClientHarness.bootstrap_location.workspace) == null,
    );
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expect(!presentationPending(&harness));
}

test "a tab drag emits one anchored move on release and never forwards the gesture" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const app = harness.client;
    _ = try harness.addTab(@enumFromInt(2), @enumFromInt(20));
    const third = try harness.addTab(@enumFromInt(3), @enumFromInt(30));
    try harness.allowTabSelection();
    try harness.settleModelPresentation();
    var drag: client_module.TabDrag = .{};

    // Press on the last tab, then drag onto the first one.
    try std.testing.expect(try pressTab(app, &drag, third, .{ 2, 0 }));
    drag.update(
        .{ 0, 0 },
        .{
            .relative_to = ClientHarness.bootstrap_location.tab_id,
            .direction = .previous,
        },
    );

    try std.testing.expectEqual(@as(?usize, 2), app.model.tabs.find(third.tab_id));
    try std.testing.expectEqual(@as(usize, 0), app.model.to_runtime.len);
    try std.testing.expectEqual(ClientHarness.bootstrap_location.tab_id, drag.destination.?.relative_to.?);

    try std.testing.expect(try releaseTab(app, &drag));
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const request = (try harness.nextClientMessage(&buffer)).move_tab;
    try std.testing.expectEqualDeep(third, request.location);
    try std.testing.expectEqual(ClientHarness.bootstrap_location.tab_id, request.relative_to.?);
    try std.testing.expectEqual(core.TabMoveDirection.previous, request.direction);
    try std.testing.expectEqual(@as(?usize, 2), app.model.tabs.find(third.tab_id));
    _ = try client_module.runtime_messages.handleServerMessage(
        app,
        .{
            .tab_moved = .{
                .request_id = request.request_id,
                .location = third,
                .position = 0,
            },
        },
    );
    try std.testing.expectEqual(@as(?usize, 0), app.model.tabs.find(third.tab_id));
    try std.testing.expect(!drag.captured);
}

test "a tab drag cancellation consumes releases outside the tab strip" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const app = harness.client;
    var drag: client_module.TabDrag = .{};

    try std.testing.expect(try pressTab(app, &drag, ClientHarness.bootstrap_location, .{ 0, 0 }));

    // Escape cancels the gesture; the drag outside the strip has no
    // destination, and the release still belongs to the cancelled gesture.
    drag.cancel();
    try std.testing.expect(drag.captured);
    drag.update(.{ 45, 10 }, null);
    try std.testing.expect(try releaseTab(app, &drag));

    try std.testing.expect(!drag.captured);
    try std.testing.expectEqual(@as(usize, 0), app.model.to_runtime.len);
    try std.testing.expect(!app.model.to_runtime.inFlight());
}

test "tab creation validates labels before retaining a request" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    const version = client.model.version();
    const next_request = client.model.request_lifecycle.next_request_id;

    try std.testing.expectError(error.InvalidTabLabel, client_module.tab_creation.requestTabCreation(
        client,
        .{
            .label = "bad\nlabel",
        },
    ));
    try std.testing.expectError(error.InvalidUtf8, client_module.tab_creation.requestTabCreation(
        client,
        .{
            .label = "\xff",
        },
    ));

    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(next_request, client.model.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "a command tab asked for while another tab operation waits is named" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    const command = try data.CommandTab.init(&.{"lazygit"}, "git");

    _ = try client_module.actions.executeAction(
        client,
        .{
            .command_tab = command,
        },
        .effect,
    );
    try std.testing.expect(client.model.limit_reaches.find("tabs.one_operation_in_flight") == null);

    _ = try client_module.actions.executeAction(
        client,
        .{
            .command_tab = command,
        },
        .effect,
    );
    try std.testing.expect(client.model.limit_reaches.find("tabs.one_operation_in_flight") != null);
}

test "tab creation outbox failure releases correlation without mutating the projection" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    while (client.model.to_runtime.hasCapacity()) {
        try client.model.to_runtime.push(.{ .detach_pane = .{ .pane_id = ClientHarness.bootstrap_pane } });
    }

    const version = client.model.version();

    try std.testing.expectError(error.ClientOutboxFull, client_module.tab_creation.requestTabCreation(
        client,
        .{},
    ));

    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqualDeep(ClientHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expect(client.model.panes.find(ClientHarness.bootstrap_pane).?.attached);
}

test "canonical tab creation remains committed when previous attachment retirement cannot be delivered" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    const request_id: core.RequestId = @enumFromInt(4);
    try client.model.request_lifecycle.tracker.add(request_id, .{ .create_tab = .{
        .workspace = ClientHarness.bootstrap_location.workspace,
        .size = .{ .cols = 80, .rows = 20 },
    } });
    while (client.model.to_runtime.hasCapacity()) {
        try client.model.to_runtime.push(.{ .detach_pane = .{ .pane_id = ClientHarness.bootstrap_pane } });
    }

    const location: core.TabLocation = .{
        .workspace = ClientHarness.bootstrap_location.workspace,
        .tab_id = @enumFromInt(2),
    };
    const created: core.TabCreated = .{
        .request_id = request_id,
        .location = location,
        .position = 1,
        .label = "second",
        .root_pane_id = @enumFromInt(20),
    };

    try std.testing.expectError(error.ClientOutboxFull, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .tab_created = created,
        },
    ));

    try std.testing.expectEqualDeep(location, client.model.activeTabLocation().?);
    try std.testing.expectEqual(@as(usize, 2), client.model.tabs.count);
    try std.testing.expect(client.model.panes.find(@enumFromInt(20)).?.attached);
    try std.testing.expect(client.model.panes.find(ClientHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabCreated, client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .tab_created = created,
        },
    ));
}

/// Whether the model holds a version the presentation has not prepared yet:
/// the damage an adapter schedules a frame for.
fn presentationPending(harness: *const ClientHarness) bool {
    return !std.meta.eql(harness.client.presentation.prepared.model, harness.client.model.version());
}

/// Delivers one image for a pane through the client's graphics port.
fn retainImage(client: *client_module.Client, pane_id: core.PaneId) !void {
    try client.graphics.apply(.{
        .image = .{
            .pane_id = pane_id,
            .revision = 1,
            .image = .{
                .key = .{
                    .image_id = 1,
                    .generation = 1,
                },
                .format = .rgb,
                .width = 1,
                .height = 1,
                .byte_len = 3,
            },
        },
    });
}

/// Presses a tab the way an adapter's chrome does: the gesture starts, the
/// press selects the tab, and the pane never sees it.
fn pressTab(client: *client_module.Client, drag: *client_module.TabDrag, location: core.TabLocation, point: [2]f64) !bool {
    drag.begin(location, point);
    const outcome = try client_module.view_interactions.apply(
        client,
        client.model.tabs.activeSlot().?,
        .{
            .intent = .{
                .select_tab = location.tab_id,
            },
            .consumed = true,
        },
    );

    return outcome.consume_pane_input;
}

/// Releases a tab gesture, applying the one move a valid drop produces.
/// A release that ends a cancelled gesture is still consumed.
fn releaseTab(client: *client_module.Client, drag: *client_module.TabDrag) !bool {
    const move = drag.finish() orelse return true;
    const outcome = try client_module.view_interactions.apply(
        client,
        client.model.tabs.activeSlot().?,
        .{
            .intent = .{
                .move_tab = move,
            },
            .consumed = true,
        },
    );

    return outcome.consume_pane_input;
}

