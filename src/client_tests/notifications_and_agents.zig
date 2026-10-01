//! Client integration tests for notifications and agents.
const keyinput = @import("keyinput");

const pacing = @import("pacing");
const data = @import("model");
const core = @import("telar-core");
const client_module = @import("telar-client");
const ClientHarness = @import("ClientHarness.zig");
const std = @import("std");
const fixtures = @import("fixtures.zig");

test "a failed request surfaces as a notification" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    try client.model.request_lifecycle.tracker.add(@enumFromInt(4), .{ .close_pane = .{
        .pane_id = ClientHarness.bootstrap_pane,
        .location = ClientHarness.bootstrap_location,
    } });
    var payload: [256]u8 = undefined;
    const failed = try core.encodeRequestFailed(&payload, .{
        .request_id = @enumFromInt(4),
        .code = .pane_not_found,
        .message = "no such pane",
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(failed));
    try harness.settle();
    const notification = client.model.notification_center.itemAt(0).?;

    try std.testing.expect(client.model.notification_scheduler.pending);
    try std.testing.expectEqualStrings("Could not close pane", notification.title());
    try std.testing.expectEqualStrings("no such pane", notification.message());
    try std.testing.expectEqualDeep(
        data.NotificationTarget{ .select_tab = ClientHarness.bootstrap_location.tab_id },
        notification.target,
    );

    const unknown = try core.encodeRequestFailed(&payload, .{
        .request_id = @enumFromInt(99),
        .code = .pane_not_found,
        .message = "no such request",
    });
    try std.testing.expectError(
        error.UnexpectedRequestFailure,
        client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(unknown)),
    );
}

test "a failed snapshot request is fatal after consuming its continuation" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: core.RequestId = @enumFromInt(4);
    try client.model.request_lifecycle.tracker.add(request_id, .{
        .workspace_snapshot = ClientHarness.bootstrap_location.workspace,
    });

    var payload: [256]u8 = undefined;
    const failed = try core.encodeRequestFailed(&payload, .{
        .request_id = request_id,
        .code = .workspace_not_found,
        .message = "workspace disappeared",
    });

    try std.testing.expectError(
        error.RuntimeRequestFailed,
        client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(failed)),
    );
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(u8, 0), client.model.notification_center.count);
}

test "a vanished remembered pane retries its workspace once before failing fatally" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: core.RequestId = @enumFromInt(4);
    const workspace: core.WorkspaceId = @enumFromInt(7);
    try client.model.request_lifecycle.tracker.add(request_id, .{ .initial_open = .{ .fallback_workspace = workspace } });
    var payload: [256]u8 = undefined;
    const failed = try core.encodeRequestFailed(&payload, .{
        .request_id = request_id,
        .code = .pane_not_found,
        .message = "remembered pane disappeared",
    });

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(failed));
    try std.testing.expectEqual(@as(u8, 0), client.model.notification_center.count);
    try harness.settle();
    var outbound: [512]u8 = undefined;
    const retried = try harness.nextClientMessage(&outbound);
    try std.testing.expect(retried == .open_pane);
    try std.testing.expectEqualDeep(core.PaneTarget{ .workspace = workspace }, retried.open_pane.target);
    const retry_failed = try core.encodeRequestFailed(&payload, .{
        .request_id = retried.open_pane.request_id,
        .code = .pane_not_found,
        .message = "workspace no longer has a pane",
    });

    try std.testing.expectError(error.RuntimeRequestFailed, client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(retry_failed)));
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
    try std.testing.expectEqual(@as(u8, 0), client.model.notification_center.count);
}

test "a runtime notification translates and owns its wire payload" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const version_before = client.model.version();
    const observed_before = client.presentation.observed;
    var payload: [512]u8 = undefined;
    const encoded = try core.encodeNotification(&payload, .{
        .level = .warning,
        .duration_ms = 2500,
        .target = .{ .tab = @enumFromInt(3) },
        .title = "Agent waiting",
        .message = "Review its question",
    });

    _ = try client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .notification = (try core.decodeServer(encoded)).notification,
        },
    );
    @memset(&payload, 'x');

    const item = client.model.notification_center.itemAt(0).?;
    try std.testing.expectEqual(version_before.notifications + 1, client.model.version().notifications);
    try std.testing.expectEqual(data.NotificationLevel.warning, item.level);
    try std.testing.expectEqual(
        data.NotificationTarget{ .select_tab = @enumFromInt(3) },
        item.target,
    );
    try std.testing.expectEqualStrings("Agent waiting", item.title());
    try std.testing.expectEqualStrings("Review its question", item.message());
    try std.testing.expectEqual(
        data.notifications.transition_duration_ns + 2500 * std.time.ns_per_ms,
        item.expires_at_ns - item.transition_updated_ns,
    );
    try std.testing.expectEqual(version_before.notifications + 1, client.model.version().notifications);
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);
    try std.testing.expect(client.model.notification_scheduler.pending);
}

test "notification action delivers one correlated runtime request without model effects" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: core.RequestId = @enumFromInt(client.model.request_lifecycle.next_request_id);
    const version_before = client.model.version();
    const observed_before = client.presentation.observed;
    try client.model.to_runtime.push(
        .{
            .detach_pane = .{
                .pane_id = ClientHarness.bootstrap_pane,
            },
        },
    );
    var notification = try data.Notification.init(.{
        .level = .warning,
        .duration_ms = 2500,
        .target = .{ .tab = @enumFromInt(3) },
        .title = "Agent waiting",
        .message = "Review its question",
    });

    try std.testing.expectEqual(
        keyinput.Control.continue_routing,
        try client_module.actions.executeAction(
            client,
            .{
                .notification = notification,
            },
            .effect,
        ),
    );

    try std.testing.expect(client.model.request_lifecycle.tracker.has(.notification));
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);
    @memset(&notification.title_bytes, 'x');
    @memset(&notification.message_bytes, 'y');

    try harness.settle();
    var message_buffer: [512]u8 = undefined;
    const first = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(first == .detach_pane);
    const message = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(message == .show_notification);
    try std.testing.expectEqual(request_id, message.show_notification.request_id);
    try std.testing.expectEqual(core.NotificationLevel.warning, message.show_notification.notification.level);
    try std.testing.expectEqual(@as(u32, 2500), message.show_notification.notification.duration_ms);
    try std.testing.expectEqualDeep(
        core.NotificationTarget{ .tab = @enumFromInt(3) },
        message.show_notification.notification.target,
    );
    try std.testing.expectEqualStrings("Agent waiting", message.show_notification.notification.title);
    try std.testing.expectEqualStrings("Review its question", message.show_notification.notification.message);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqualDeep(observed_before.model, client.presentation.observed.model);
}

test "notification request rolls correlation back when transport is full" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    while (client.model.to_runtime.hasCapacity()) {
        try client.model.to_runtime.push(.{
            .detach_pane = .{ .pane_id = ClientHarness.bootstrap_pane },
        });
    }
    const next_request_id = client.model.request_lifecycle.next_request_id;
    const version_before = client.model.version();
    const observed_before = client.presentation.observed;
    const notification = try data.Notification.init(.{
        .level = .info,
        .duration_ms = core.default_notification_duration_ms,
        .target = .none,
        .title = "Build complete",
        .message = "Review the output",
    });

    try std.testing.expectError(
        error.ClientOutboxFull,
        client_module.actions.executeAction(
            client,
            .{
                .notification = notification,
            },
            .effect,
        ),
    );

    try std.testing.expectEqual(next_request_id + 1, client.model.request_lifecycle.next_request_id);
    try std.testing.expect(client.model.request_lifecycle.tracker.isEmpty());
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);
}

test "notification timer commits lifecycle state before presenter observation" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const now_ns = pacing.clock.monotonic(client.io);
    _ = try client_module.notifications.publishNotification(client, now_ns, .{
        .title = "Building",
        .message = "Lifecycle tick",
    });
    const observed = client.presentation.observed;

    try std.testing.expect(client.model.notification_scheduler.pending);
    switch (try harness.receiveClient()) {
        .notification_tick => |result| {
            const change = (try client_module.notifications.completeNotificationTick(client, result)).?;

            try std.testing.expectEqual(
                client.model.version().notifications,
                change.notifications_revision,
            );
        },
        else => return error.UnexpectedEvent,
    }

    try std.testing.expect(client.model.notification_scheduler.pending);
    try std.testing.expectEqual(@as(u64, 2), client.model.version().notifications);
    try std.testing.expectEqualDeep(observed, client.presentation.observed);

    try harness.present();

    try std.testing.expectEqualDeep(client.model.version(), client.presentation.delivered.model);
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.observed.model);
}

test "an unexpected notification delivery report is rejected without effects" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const version_before = client.model.version();
    const shown: core.NotificationShown = .{
        .request_id = @enumFromInt(99),
        .delivered_clients = 1,
    };

    try std.testing.expectError(
        error.UnexpectedNotificationReply,
        client_module.runtime_messages.handleServerMessage(
            client,
            .{
                .notification_shown = shown,
            },
        ),
    );

    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(@as(u8, 0), client.model.notification_center.count);
    try std.testing.expect(!client.model.notification_scheduler.pending);
}

test "notification delivery consumes an incompatible continuation before rejection" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: core.RequestId = @enumFromInt(90);
    try client.model.request_lifecycle.tracker.add(request_id, .{ .move_tab = ClientHarness.bootstrap_location });
    const shown: core.NotificationShown = .{
        .request_id = request_id,
        .delivered_clients = 1,
    };

    try std.testing.expectError(
        error.UnexpectedNotificationReply,
        client_module.runtime_messages.handleServerMessage(
            client,
            .{
                .notification_shown = shown,
            },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectError(
        error.UnexpectedNotificationReply,
        client_module.runtime_messages.handleServerMessage(
            client,
            .{
                .notification_shown = shown,
            },
        ),
    );
    try std.testing.expectEqual(@as(u8, 0), client.model.notification_center.count);
    try std.testing.expect(!client.model.notification_scheduler.pending);
}

test "a delivered notification report consumes correlation without model effects" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: core.RequestId = @enumFromInt(90);
    const version_before = client.model.version();
    try client.model.request_lifecycle.tracker.add(request_id, .notification);

    try std.testing.expectEqual(
        @as(?u8, null),
        try client_module.runtime_messages.handleServerMessage(
            client,
            .{
                .notification_shown = .{
                    .request_id = request_id,
                    .delivered_clients = 2,
                },
            },
        ),
    );

    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(@as(u8, 0), client.model.notification_center.count);
    try std.testing.expect(!client.model.notification_scheduler.pending);
}

test "runtime notifications and delivery failures reach the toasts" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;

    var payload: [256]u8 = undefined;
    const notification = try core.encodeNotification(&payload, .{ .title = "hello" });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(notification));
    try std.testing.expect(client.model.notification_scheduler.pending);
    const version_after_runtime = client.model.version();

    try client.model.request_lifecycle.tracker.add(@enumFromInt(2), .notification);
    const shown = try core.encodeNotificationShown(&payload, .{
        .request_id = @enumFromInt(2),
        .delivered_clients = 0,
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(shown));
    const snapshot = &client.model.notification_center;

    try std.testing.expectEqual(version_after_runtime.notifications + 1, client.model.version().notifications);
    try std.testing.expectEqual(@as(u8, 2), snapshot.count);
    try std.testing.expectEqualStrings("Notification not delivered", snapshot.itemAt(0).?.title());
    try std.testing.expectEqualStrings(
        "No connected client could accept the notification",
        snapshot.itemAt(0).?.message(),
    );
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);

    const unexpected = try core.encodeNotificationShown(&payload, .{
        .request_id = @enumFromInt(9),
        .delivered_clients = 1,
    });
    try std.testing.expectError(
        error.UnexpectedNotificationReply,
        client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(unexpected)),
    );
    try harness.settle();
}

test "a toast that carries a link opens it through the link opener when clicked" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const url = "https://auth.openai.com/codex/device";
    var payload: [512]u8 = undefined;
    const encoded = try core.encodeNotification(&payload, .{
        .title = "Log in to Codex",
        .message = "on box: open the page, sign in and enter the code",
        .link = url,
    });

    _ = try client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .notification = (try core.decodeServer(encoded)).notification,
        },
    );
    @memset(&payload, 'x');

    const item = client.model.notification_center.itemAt(0).?;
    try std.testing.expect(item.clickable());
    try std.testing.expectEqualStrings(url, item.link());
    while (client.to_background.pop()) |_| {}

    const activation: client_module.ViewInteractionCommand = .{
        .intent = .{
            .notification_activate = item.id,
        },
    };
    _ = try client_module.view_interactions.apply(client, client.model.tabs.active, activation);

    const job = client.to_background.pop() orelse return error.TestExpectedLinkJob;
    try std.testing.expectEqualStrings(url, job.link.uri());
    try std.testing.expectEqual(@as(?client_module.BackgroundJob, null), client.to_background.pop());
}

test "a remote runtime's toast arrives without its link" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const saved = client.options.machine;
    defer client.options.machine = saved;
    client.options.machine = .{ .remote = .{
        .destination = "dev@box",
        .arguments = &.{},
    } };

    var payload: [512]u8 = undefined;
    const encoded = try core.encodeNotification(&payload, .{
        .title = "Log in to Claude",
        .message = "your session expired",
        .link = "https://claude.ai.login.example/",
    });
    _ = try client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .notification = (try core.decodeServer(encoded)).notification,
        },
    );

    const item = client.model.notification_center.itemAt(0).?;
    try std.testing.expectEqualStrings("Log in to Claude", item.title());
    try std.testing.expectEqual(@as(u16, 0), item.link_len);
    try std.testing.expect(!item.clickable());
}

test "toast activation commits by id before following its navigation target" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const active = client.model.tabs.active;
    const second_pane: core.PaneId = @enumFromInt(11);
    try data.pane_split.split(&client.model, active, .{ .existing_pane = ClientHarness.bootstrap_pane, .new_pane = second_pane, .location = ClientHarness.bootstrap_location, .axis = .horizontal, .area = client.geometry().area });
    try std.testing.expect(client.model.tabs.layout[active].focusPane(ClientHarness.bootstrap_pane));

    try client_module.notifications.publishNotificationNow(client, .{
        .title = "Ready",
        .message = "Open pane",
        .target = .{ .focus_pane = second_pane },
    });
    const item = client.model.notification_center.itemAt(0).?;
    const notification_id = item.id;
    const visible_at_ns = item.transition_updated_ns + data.notifications.transition_duration_ns;
    _ = data.notifications.advance(&client.model, visible_at_ns);

    const activation: client_module.ViewInteractionCommand = .{
        .intent = .{
            .notification_activate = notification_id,
        },
    };
    const version_before_activation = client.model.version();

    _ = try client_module.view_interactions.apply(client, active, activation);

    try std.testing.expectEqual(second_pane, client.model.tabs.layout[active].focused().?);
    try std.testing.expectEqual(
        version_before_activation.notifications + 1,
        client.model.version().notifications,
    );
    const version_after_activation = client.model.version();

    _ = try client_module.view_interactions.apply(client, active, activation);

    try std.testing.expectEqualDeep(version_after_activation, client.model.version());
}

test "proxy status commits before announcement and presenter-owned projection" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const observed_before = client.presentation.observed;

    var payload: [64]u8 = undefined;
    const enabled = try core.encodeProxyStatus(&payload, .{ .active = true, .scope = .wildcard, .system_trusted = false });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(enabled));

    try std.testing.expect(client.model.proxy_tls_active);
    try std.testing.expectEqual(version_before.proxy_status + 1, client.model.version().proxy_status);
    try std.testing.expectEqual(version_before.notifications + 1, client.model.version().notifications);
    try std.testing.expectEqual(version_before.proxy_status, client.presentation.observed.model.proxy_status);
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);
    try std.testing.expectEqual(@as(u8, 1), client.model.notification_center.count);
    try std.testing.expectEqualStrings(
        "TLS interception active",
        client.model.notification_center.itemAt(0).?.title(),
    );

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(enabled));

    try std.testing.expectEqual(version_before.proxy_status + 1, client.model.version().proxy_status);
    try std.testing.expectEqual(version_before.notifications + 1, client.model.version().notifications);
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);
    try std.testing.expectEqual(@as(u8, 1), client.model.notification_center.count);

    try harness.present();
    const enabled_version = client.model.version();

    try std.testing.expectEqualDeep(enabled_version, client.presentation.delivered.model);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);
    try std.testing.expectEqual(
        enabled_version.proxy_status,
        client.presentation.prepared.model.proxy_status,
    );

    const observed_after_enabled = client.presentation.observed;
    const version_before_disabled = client.model.version();
    const disabled = try core.encodeProxyStatus(&payload, .{ .active = false, .scope = .exact, .system_trusted = false });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(disabled));

    try std.testing.expect(!client.model.proxy_tls_active);
    try std.testing.expectEqual(version_before_disabled.proxy_status + 1, client.model.version().proxy_status);
    try std.testing.expectEqual(version_before_disabled.notifications + 1, client.model.version().notifications);
    try std.testing.expectEqualDeep(observed_after_enabled, client.presentation.observed);
    try std.testing.expectEqual(@as(u8, 2), client.model.notification_center.count);
    try std.testing.expectEqualStrings(
        "TLS interception stopped",
        client.model.notification_center.itemAt(0).?.title(),
    );

    try harness.present();
    const disabled_version = client.model.version();
    try harness.settleModelPresentation();

    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);
    try std.testing.expectEqual(
        disabled_version.proxy_status,
        client.presentation.prepared.model.proxy_status,
    );
}

test "system metrics commit before presenter-owned projection" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const observed_before = client.presentation.observed;

    var payload: [64]u8 = undefined;
    const metrics = try core.encodeSystemMetrics(&payload, .{
        .revision = 7,
        .cpu_percent = 50,
        .memory_used_decigib = 10,
        .has_battery = true,
        .battery_percent = 80,
        .cpu_count = 4,
        .memory_total_decigib = 160,
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(metrics));

    try std.testing.expectEqualDeep(data.SystemMetrics{
        .runtime_revision = 7,
        .cpu_percent = 50,
        .memory_used_decigib = 10,
        .battery_percent = 80,
        .cpu_count = 4,
        .memory_total_decigib = 160,
    }, client.model.system_metrics.?);
    try std.testing.expectEqual(version_before.system_metrics + 1, client.model.version().system_metrics);
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(metrics));
    try std.testing.expectEqual(version_before.system_metrics + 1, client.model.version().system_metrics);
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);

    try harness.present();

    try std.testing.expectEqualDeep(client.model.version(), client.presentation.delivered.model);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);
}

test "workspace list snapshots commit before presenter-owned projection" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const observed_before = client.presentation.observed;

    var payload: [512]u8 = undefined;
    const list = try core.encodeWorkspaceList(&payload, .{
        .revision = 7,
        .entries = &.{
            .{ .workspace = @enumFromInt(1), .name = "main", .path = "/work/main", .tab_count = 1 },
            .{ .workspace = @enumFromInt(2), .name = "api", .path = "/work/api", .tab_count = 2 },
        },
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(list));

    try std.testing.expect(data.workspace_list_snapshot.knowsWorkspace(&client.model, @enumFromInt(1)));
    try std.testing.expect(data.workspace_list_snapshot.knowsWorkspace(&client.model, @enumFromInt(2)));
    try std.testing.expectEqualStrings("/work/api", client.model.workspace_list_snapshot.pathAt(1));
    try std.testing.expectEqual(version_before.workspace_list + 1, client.model.version().workspace_list);
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(list));
    try std.testing.expectEqual(version_before.workspace_list + 1, client.model.version().workspace_list);
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);

    try harness.present();

    try std.testing.expectEqualDeep(client.model.version(), client.presentation.delivered.model);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);
}

test "workspace position navigation resolves the committed client model" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};

    var payload: [512]u8 = undefined;
    const list = try core.encodeWorkspaceList(&payload, .{
        .revision = 1,
        .entries = &.{
            .{ .workspace = @enumFromInt(1), .name = "main", .path = "/work/main", .tab_count = 1 },
            .{ .workspace = @enumFromInt(2), .name = "api", .path = "/work/api", .tab_count = 1 },
        },
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(list));
    const observed_before = client.presentation.observed;

    _ = try client_module.actions.executeAction(
        client,
        .{
            .select_workspace = 1,
        },
        .effect,
    );

    try std.testing.expect(client.model.workspace == null);
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);
    try harness.settle();

    var message_buffer: [256]u8 = undefined;
    var target: ?core.PaneTarget = null;
    while (target == null) {
        switch (try harness.nextClientMessage(&message_buffer)) {
            .detach_pane => {},
            .open_pane => |open| target = open.target,
            else => return error.UnexpectedClientMessage,
        }
    }

    try std.testing.expectEqualDeep(
        core.PaneTarget{ .workspace = @enumFromInt(2) },
        target.?,
    );
}

test "an agent snapshot replaces the sidebar replica" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();

    var payload: [512]u8 = undefined;
    const snapshot = try core.encodeAgentSnapshot(&payload, .{
        .revision = 1,
        .entries = &.{.{
            .pane_id = ClientHarness.bootstrap_pane,
            .pane_generation = 1,
            .location = ClientHarness.bootstrap_location,
            .pane_index = 1,
            .process_id = 42,
            .session_id = @splat(0),
            .workspace_label = "telar",
            .tab_label = "test-2",
            .session_title = "Improve agent sidebar",
            .title_source = .generated,
            .title_state = .ready,
            .cwd_label = "~/sandbox/telar",
            .provider = .claude,
            .display_name = "Claude",
            .status = .working,
            .source = .screen,
            .authority = .active,
            .confidence = 1,
            .sequence = 1,
            .observed_at_ms = 1,
            .expires_at_ms = 2,
        }},
    });
    const observed = harness.client.presentation.observed;
    _ = try client_module.runtime_messages.handleServerMessage(harness.client, try core.decodeServer(snapshot));
    const agent = harness.client.model.agent_snapshot.find(.{
        .pane_id = ClientHarness.bootstrap_pane,
        .pane_generation = 1,
    }).?;
    try std.testing.expectEqualStrings("telar", agent.workspaceLabel());
    try std.testing.expectEqualStrings("test-2", agent.tabLabel());
    try std.testing.expectEqualStrings("Improve agent sidebar", agent.sessionTitle());
    try std.testing.expectEqualStrings("~/sandbox/telar", agent.cwdLabel());
    try std.testing.expectEqual(data.Version{ .agents = 1 }, harness.client.model.version());
    try std.testing.expectEqualDeep(observed, harness.client.presentation.observed);

    try harness.settleModelPresentation();

    try std.testing.expectEqual(
        harness.client.model.version(),
        harness.client.presentation.prepared.model,
    );
}

test "sidebar animation commits model state before the presenter observes it" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    // A terminal host reports its frame interval; animation ticks only with one.
    client.model.host.animation_frame_ns = pacing.pace.default_interval;
    var payload: [512]u8 = undefined;
    const snapshot = try fixtures.encodeTestingAgentSnapshot(&payload, 1, .working);
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(snapshot));
    const observed = client.presentation.observed;

    try std.testing.expect(client.model.sidebar_animation_scheduler.pending);
    try std.testing.expectEqual(@as(u8, 0), client.model.sidebar_animation_frame);
    switch (try harness.receiveClient()) {
        .sidebar_animation_tick => |result| {
            const change = (try client_module.sidebar_animation.completeSidebarAnimationTick(client, result)).?;

            try std.testing.expectEqual(@as(u8, 1), change.frame);
            try std.testing.expectEqual(@as(u64, 1), change.sidebar_animation_revision);
        },
        else => return error.UnexpectedEvent,
    }

    try std.testing.expect(client.model.sidebar_animation_scheduler.pending);
    try std.testing.expectEqual(data.Version{
        .agents = 1,
        .sidebar_animation = 1,
    }, client.model.version());
    try std.testing.expectEqual(@as(u8, 1), client.model.sidebar_animation_frame);
    try std.testing.expectEqualDeep(observed, client.presentation.observed);

    try harness.present();

    try std.testing.expectEqualDeep(client.model.version(), client.presentation.delivered.model);
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.observed.model);
}

test "agent snapshot transitions raise bounded presentation alerts only once" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    var payload: [512]u8 = undefined;

    const initial = try fixtures.encodeTestingAgentSnapshot(&payload, 1, .ready);
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(initial));

    try std.testing.expectEqual(@as(u8, 0), client.model.notification_center.count);
    try std.testing.expectEqual(data.Version{ .agents = 1 }, client.model.version());

    const changed = try fixtures.encodeTestingAgentSnapshot(&payload, 2, .blocked);
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(changed));
    const notification = client.model.notification_center.itemAt(0).?;

    try std.testing.expectEqual(data.Version{ .agents = 2, .notifications = 1 }, client.model.version());
    try std.testing.expectEqual(@as(u8, 1), client.model.notification_center.count);
    try std.testing.expectEqual(data.NotificationLevel.warning, notification.level);
    try std.testing.expectEqualStrings("Agent needs input", notification.title());
    try std.testing.expectEqualStrings("Claude in pane 3 is waiting for input", notification.message());
    try std.testing.expectEqualDeep(
        data.NotificationTarget{ .focus_pane = ClientHarness.bootstrap_pane },
        notification.target,
    );

    const stale = try fixtures.encodeTestingAgentSnapshot(&payload, 1, .failed);
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(stale));

    try std.testing.expectEqual(data.Version{ .agents = 2, .notifications = 1 }, client.model.version());
    try std.testing.expectEqual(@as(u8, 1), client.model.notification_center.count);
}

test "agent sounds validate exact identity against the client model" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    var payload: [512]u8 = undefined;
    const snapshot = try fixtures.encodeTestingAgentSnapshot(&payload, 1, .ready);
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(snapshot));
    const version_before_sound = client.model.version();
    const observed = client.presentation.observed;

    const unknown = try core.encodeAgentSound(&payload, .{
        .pane_id = ClientHarness.bootstrap_pane,
        .pane_generation = 2,
        .sound = .ready,
    });
    _ = try client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .agent_sound = (try core.decodeServer(unknown)).agent_sound,
        },
    );

    try std.testing.expect(!client.model.sound_playback.snapshot().active);

    const known = try core.encodeAgentSound(&payload, .{
        .pane_id = ClientHarness.bootstrap_pane,
        .pane_generation = 1,
        .sound = .ready,
    });
    _ = try client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .agent_sound = (try core.decodeServer(known)).agent_sound,
        },
    );

    try std.testing.expect(client.model.sound_playback.snapshot().active);

    const urgent = try core.encodeAgentSound(&payload, .{
        .pane_id = ClientHarness.bootstrap_pane,
        .pane_generation = 1,
        .sound = .needs_input,
    });
    _ = try client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .agent_sound = (try core.decodeServer(urgent)).agent_sound,
        },
    );

    try std.testing.expectEqual(core.AgentSound.needs_input, client.model.sound_playback.snapshot().queued.?);
    try std.testing.expectEqualDeep(version_before_sound, client.model.version());
    try std.testing.expectEqualDeep(observed, client.presentation.observed);
}

test "agent sound completion releases a failed worker before scheduling its successor" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const version_before = client.model.version();
    const observed = client.presentation.observed;

    try std.testing.expectEqualDeep(
        data.SoundRequestOutcome{ .start = .ready },
        client.model.sound_playback.request(.ready),
    );
    try std.testing.expect(client.model.sound_playback.request(.needs_input) == .queued);

    try client_module.agent_sound.completeAgentSound(client, error.SoundUnavailable);

    try std.testing.expectEqual(data.SoundSnapshot{
        .configuration = .{},
        .active = true,
        .queued = null,
    }, client.model.sound_playback.snapshot());
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqualDeep(observed, client.presentation.observed);
}

test "a sound the host cannot start releases its token and does not poison a later request" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    var payload: [512]u8 = undefined;
    const initial = try fixtures.encodeTestingAgentSnapshot(&payload, 1, .ready);
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(initial));
    try harness.deliverHostEffects();
    const message = try core.encodeAgentSound(&payload, .{
        .pane_id = ClientHarness.bootstrap_pane,
        .pane_generation = 1,
        .sound = .ready,
    });

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(message));
    const job = client.to_background.pop().?;
    try std.testing.expect(job == .sound);
    try client.failBackgroundJob(job, error.SoundSchedulingFailed);

    try std.testing.expect(!client.model.sound_playback.snapshot().active);
    try std.testing.expect(client.model.sound_playback.snapshot().queued == null);
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(message));
    try std.testing.expect(client.model.sound_playback.snapshot().active);
}

test "agent snapshot folds alerts past the center into one summary while retaining every status change" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    var entries: [data.notifications.max_items + 2]core.AgentSnapshotEntry = undefined;
    for (&entries, 0..) |*entry, index| {
        entry.* = .{
            .pane_id = @enumFromInt(index + 1),
            .pane_generation = 1,
            .location = ClientHarness.bootstrap_location,
            .pane_index = @intCast(index + 1),
            .process_id = 42,
            .session_id = @splat(0),
            .provider = .claude,
            .display_name = "Claude",
            .status = .ready,
            .source = .screen,
            .authority = .active,
            .confidence = 1,
            .sequence = 1,
            .observed_at_ms = 1,
            .expires_at_ms = 2,
        };
    }
    var payload: [8192]u8 = undefined;
    const initial = try core.encodeAgentSnapshot(&payload, .{ .revision = 1, .entries = &entries });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(initial));
    const statuses = [_]core.AgentStatus{ .blocked, .done, .failed };
    for (&entries, 0..) |*entry, index| {
        entry.status = statuses[index % statuses.len];
        entry.sequence = 2;
    }
    const changed = try core.encodeAgentSnapshot(&payload, .{ .revision = 2, .entries = &entries });

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(changed));

    // Three alerts by themselves and one summary of the other three: the
    // batch fills the center without evicting any of its own alerts.
    try std.testing.expectEqual(@as(u64, data.notifications.max_items), client.model.version().notifications);
    try std.testing.expectEqual(data.notifications.max_items, client.model.notification_center.count);
    var summary: ?*const data.NotificationItem = null;
    for (0..client.model.notification_center.count) |index| {
        const item = client.model.notification_center.itemAt(index).?;
        if (std.mem.eql(u8, item.title(), "More agents changed")) {
            summary = item;
        }
    }

    try std.testing.expectEqualStrings("3 more agents: 1 waiting for input, 1 done, 1 failed", summary.?.message());
    try std.testing.expectEqual(data.NotificationLevel.failure, summary.?.level);
    try std.testing.expectEqual(entries.len, client.model.agent_snapshot.count);
    for (entries) |entry| {
        try std.testing.expectEqual(entry.status, client.model.agent_snapshot.find(.{ .pane_id = entry.pane_id, .pane_generation = entry.pane_generation }).?.status);
    }
    const version = client.model.version();
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(changed));
    try std.testing.expectEqualDeep(version, client.model.version());
}

test "attachment rejection consumes correlation but does not notify when recovery delivery fails" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    client.model.panes.find(ClientHarness.bootstrap_pane).?.attached = false;
    const request_id = try client.model.request_lifecycle.nextId();
    try client.model.request_lifecycle.tracker.add(request_id, .{ .attach_pane = .{
        .pane_id = ClientHarness.bootstrap_pane,
        .location = ClientHarness.bootstrap_location,
    } });
    while (client.model.to_runtime.hasCapacity()) {
        try client.model.to_runtime.push(.{ .detach_pane = .{ .pane_id = ClientHarness.bootstrap_pane } });
    }
    const version = client.model.version();
    var payload: [256]u8 = undefined;
    const failed = try core.encodeRequestFailed(&payload, .{
        .request_id = request_id,
        .code = .pane_not_found,
        .message = "pane disappeared",
    });

    try std.testing.expectError(error.ClientOutboxFull, client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(failed)));

    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(@as(u8, 0), client.model.notification_center.count);
    try std.testing.expectError(error.UnexpectedRequestFailure, client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(failed)));
}
