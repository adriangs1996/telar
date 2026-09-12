//! Client integration tests for notifications and agents.

const TerminalClient = @import("../TerminalClient.zig");
const host = TerminalClient.of;
const TestHarness = @import("TestHarness.zig");
const encodeRequestFailed_module = @import("telar-core").encodeRequestFailed;
const server_messages = @import("telar-client").server_messages;
const decodeServer_module = @import("telar-core").decodeServer;
const std = @import("std");
const NotificationsRootTarget = @import("telar-client").NotificationTarget;
const RequestIdType = @import("telar-core").RequestId;
const encodeNotification_module = @import("telar-core").encodeNotification;
const notification_flow = @import("telar-client").controllers.notifications;
const LevelType = @import("telar-client").Level;
const transition_duration_ns_module = @import("telar-client").transition_duration_ns;
const runtime_transport = @import("telar-client").runtime_io;
const NotificationType = @import("telar-client").Notification;
const ControlType = @import("telar-client").Control;
const client_actions = @import("telar-client").controllers.actions;
const request_lifecycle = @import("telar-client").request_lifecycle;
const NotificationLevelType = @import("telar-core").NotificationLevel;
const NotificationTargetType = @import("telar-core").NotificationTarget;
const default_notification_duration_ms_module = @import("telar-core").default_notification_duration_ms;
const monotonic_module = @import("telar-client").monotonic;
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const NotificationShownType = @import("telar-core").NotificationShown;
const DeliveryOutcomeType = @import("telar-client").DeliveryOutcome;
const encodeNotificationShown_module = @import("telar-core").encodeNotificationShown;
const PaneIdType = @import("telar-core").PaneId;
const term = @import("../../presentation/screen_support.zig");
const InputHandler = @import("../resources/InputHandler.zig");
const encodeProxyStatus_module = @import("telar-core").encodeProxyStatus;
const encodeSystemMetrics_module = @import("telar-core").encodeSystemMetrics;
const SystemMetricsType = @import("telar-client").SystemMetrics;
const ScreenType = @import("../../presentation/Screen.zig");
const RectType = @import("telar-core").Rect;
const encodeWorkspaceList_module = @import("telar-core").encodeWorkspaceList;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const PaneTargetType = @import("telar-core").PaneTarget;
const encodeAgentSnapshot_module = @import("telar-core").encodeAgentSnapshot;
const VersionType = @import("telar-client").Version;
const support = @import("support.zig");
const sidebar_animations = @import("telar-client").controllers.sidebar_animations;
const encodeAgentSound_module = @import("telar-core").encodeAgentSound;
const agent_sounds = @import("telar-client").controllers.agent_sounds;
const ApplicationAgentsAgentSoundOutcome = @import("telar-client").ApplicationAgentsAgentSoundOutcome;
const AgentSoundType = @import("telar-core").AgentSound;
const playback_support = @import("telar-client").sound_playback_support;
const SnapshotType = @import("telar-client").SoundSnapshot;

test "a failed request surfaces as a notification" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .close_pane = .{
        .pane_id = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
    } });
    var payload: [256]u8 = undefined;
    const failed = try encodeRequestFailed_module(&payload, .{
        .request_id = @enumFromInt(4),
        .code = .pane_not_found,
        .message = "no such pane",
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(failed));
    try harness.settle();
    const notification = client.model.notificationSnapshot().itemAt(0).?;

    try std.testing.expect(client.notification_scheduler.pending);
    try std.testing.expectEqualStrings("Could not close pane", notification.title());
    try std.testing.expectEqualStrings("no such pane", notification.message());
    try std.testing.expectEqualDeep(
        NotificationsRootTarget{ .select_tab = TestHarness.bootstrap_location.tab_id },
        notification.target,
    );

    const unknown = try encodeRequestFailed_module(&payload, .{
        .request_id = @enumFromInt(99),
        .code = .pane_not_found,
        .message = "no such request",
    });
    try std.testing.expectError(
        error.UnexpectedRequestFailure,
        server_messages.handleServerMessage(client, try decodeServer_module(unknown)),
    );
}

test "a failed snapshot request is fatal after consuming its continuation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: RequestIdType = @enumFromInt(4);
    try client.request_lifecycle.tracker.add(request_id, .{
        .workspace_snapshot = TestHarness.bootstrap_location.workspace,
    });

    var payload: [256]u8 = undefined;
    const failed = try encodeRequestFailed_module(&payload, .{
        .request_id = request_id,
        .code = .workspace_not_found,
        .message = "workspace disappeared",
    });

    try std.testing.expectError(
        error.RuntimeRequestFailed,
        server_messages.handleServerMessage(client, try decodeServer_module(failed)),
    );
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(u8, 0), client.model.notificationSnapshot().count);
}

test "a runtime notification translates and owns its wire payload" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const version_before = client.model.version();
    const pending_updates_before = host(client).presenter.pending_updates;
    var payload: [512]u8 = undefined;
    const encoded = try encodeNotification_module(&payload, .{
        .level = .warning,
        .duration_ms = 2500,
        .target = .{ .tab = @enumFromInt(3) },
        .title = "Agent waiting",
        .message = "Review its question",
    });

    const publication = try notification_flow.applyRuntime(
        client,
        (try decodeServer_module(encoded)).notification,
    );
    @memset(&payload, 'x');

    const item = client.model.notificationSnapshot().itemAt(0).?;
    try std.testing.expectEqual(item.id, publication.id);
    try std.testing.expectEqual(version_before.notifications + 1, publication.notifications_revision);
    try std.testing.expectEqual(LevelType.warning, item.level);
    try std.testing.expectEqual(
        NotificationsRootTarget{ .select_tab = @enumFromInt(3) },
        item.target,
    );
    try std.testing.expectEqualStrings("Agent waiting", item.title());
    try std.testing.expectEqualStrings("Review its question", item.message());
    try std.testing.expectEqual(
        transition_duration_ns_module + 2500 * std.time.ns_per_ms,
        item.expires_at_ns - item.transition_updated_ns,
    );
    try std.testing.expectEqual(version_before.notifications + 1, client.model.version().notifications);
    try std.testing.expectEqual(pending_updates_before, host(client).presenter.pending_updates);
    try std.testing.expect(client.notification_scheduler.pending);
}

test "notification action delivers one correlated runtime request without model effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: RequestIdType = @enumFromInt(client.request_lifecycle.next_request_id);
    const version_before = client.model.version();
    const pending_updates_before = host(client).presenter.pending_updates;
    try runtime_transport.enqueue(client, .{
        .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane },
    });
    var notification = try NotificationType.init(.{
        .level = .warning,
        .duration_ms = 2500,
        .target = .{ .tab = @enumFromInt(3) },
        .title = "Agent waiting",
        .message = "Review its question",
    });

    try std.testing.expectEqual(
        ControlType.continue_routing,
        try client_actions.apply(client, .{ .notification = notification }),
    );

    try std.testing.expect(request_lifecycle.has(client, .notification));
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, host(client).presenter.pending_updates);
    @memset(&notification.title_bytes, 'x');
    @memset(&notification.message_bytes, 'y');

    try harness.settle();
    var message_buffer: [512]u8 = undefined;
    const first = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(first == .detach_pane);
    const message = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(message == .show_notification);
    try std.testing.expectEqual(request_id, message.show_notification.request_id);
    try std.testing.expectEqual(NotificationLevelType.warning, message.show_notification.notification.level);
    try std.testing.expectEqual(@as(u32, 2500), message.show_notification.notification.duration_ms);
    try std.testing.expectEqualDeep(
        NotificationTargetType{ .tab = @enumFromInt(3) },
        message.show_notification.notification.target,
    );
    try std.testing.expectEqualStrings("Agent waiting", message.show_notification.notification.title);
    try std.testing.expectEqualStrings("Review its question", message.show_notification.notification.message);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, host(client).presenter.pending_updates);
}

test "notification request rolls correlation back when transport is full" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    while (client.runtime_transport.outbox.hasCapacity()) {
        try client.runtime_transport.outbox.push(.{
            .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane },
        });
    }
    const next_request_id = client.request_lifecycle.next_request_id;
    const version_before = client.model.version();
    const pending_updates_before = host(client).presenter.pending_updates;
    const notification = try NotificationType.init(.{
        .level = .info,
        .duration_ms = default_notification_duration_ms_module,
        .target = .none,
        .title = "Build complete",
        .message = "Review the output",
    });

    try std.testing.expectError(
        error.ClientOutboxFull,
        notification_flow.requestDelivery(client, &notification),
    );

    try std.testing.expectEqual(next_request_id + 1, client.request_lifecycle.next_request_id);
    try std.testing.expect(client.request_lifecycle.tracker.isEmpty());
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, host(client).presenter.pending_updates);
}

test "notification timer commits lifecycle state before presenter observation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const now_ns = monotonic_module(client.io);
    _ = try notification_flow.publish(client, now_ns, .{
        .title = "Building",
        .message = "Lifecycle tick",
    });
    const pending_updates = host(client).presenter.pending_updates;

    try std.testing.expect(client.notification_scheduler.pending);
    switch (try host(client).select.await()) {
        .notification_tick => |result| {
            const change = (try notification_flow.handleTick(client, result)).?;

            try std.testing.expectEqual(
                client.model.version().notifications,
                change.notifications_revision,
            );
        },
        else => return error.UnexpectedEvent,
    }

    try std.testing.expect(client.notification_scheduler.pending);
    try std.testing.expectEqual(@as(u64, 2), client.model.version().notifications);
    try std.testing.expectEqual(pending_updates, host(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates + 1, host(client).presenter.pending_updates);
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.observed.model);
}

test "an unexpected notification delivery report is rejected without effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const version_before = client.model.version();
    const shown: NotificationShownType = .{
        .request_id = @enumFromInt(99),
        .delivered_clients = 1,
    };

    try std.testing.expectError(
        error.UnexpectedNotificationReply,
        notification_flow.applyDeliveryReport(client, shown),
    );

    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(@as(u8, 0), client.model.notificationSnapshot().count);
    try std.testing.expect(!client.notification_scheduler.pending);
}

test "notification delivery consumes an incompatible continuation before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: RequestIdType = @enumFromInt(90);
    try client.request_lifecycle.tracker.add(request_id, .{ .move_tab = TestHarness.bootstrap_location });
    const shown: NotificationShownType = .{
        .request_id = request_id,
        .delivered_clients = 1,
    };

    try std.testing.expectError(
        error.UnexpectedNotificationReply,
        notification_flow.applyDeliveryReport(client, shown),
    );
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectError(
        error.UnexpectedNotificationReply,
        notification_flow.applyDeliveryReport(client, shown),
    );
    try std.testing.expectEqual(@as(u8, 0), client.model.notificationSnapshot().count);
    try std.testing.expect(!client.notification_scheduler.pending);
}

test "a delivered notification report consumes correlation without model effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: RequestIdType = @enumFromInt(90);
    const version_before = client.model.version();
    try client.request_lifecycle.tracker.add(request_id, .notification);

    try std.testing.expectEqual(
        DeliveryOutcomeType.delivered,
        try notification_flow.applyDeliveryReport(client, .{
            .request_id = request_id,
            .delivered_clients = 2,
        }),
    );

    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(@as(u8, 0), client.model.notificationSnapshot().count);
    try std.testing.expect(!client.notification_scheduler.pending);
}

test "runtime notifications and delivery failures reach the toasts" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;

    var payload: [256]u8 = undefined;
    const notification = try encodeNotification_module(&payload, .{ .title = "hello" });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(notification));
    try std.testing.expect(client.notification_scheduler.pending);
    const version_after_runtime = client.model.version();

    try client.request_lifecycle.tracker.add(@enumFromInt(2), .notification);
    const shown = try encodeNotificationShown_module(&payload, .{
        .request_id = @enumFromInt(2),
        .delivered_clients = 0,
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(shown));
    const snapshot = client.model.notificationSnapshot();

    try std.testing.expectEqual(version_after_runtime.notifications + 1, client.model.version().notifications);
    try std.testing.expectEqual(@as(u8, 2), snapshot.count);
    try std.testing.expectEqualStrings("Notification not delivered", snapshot.itemAt(0).?.title());
    try std.testing.expectEqualStrings(
        "No connected client could accept the notification",
        snapshot.itemAt(0).?.message(),
    );
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);

    const unexpected = try encodeNotificationShown_module(&payload, .{
        .request_id = @enumFromInt(9),
        .delivered_clients = 1,
    });
    try std.testing.expectError(
        error.UnexpectedNotificationReply,
        server_messages.handleServerMessage(client, try decodeServer_module(unexpected)),
    );
    try harness.settle();
}

test "toast activation commits by id before following its navigation target" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const active = &client.model.workspace.active().?.model;
    const second_pane: PaneIdType = @enumFromInt(11);
    try active.split(.{ .existing_pane = TestHarness.bootstrap_pane, .new_pane = second_pane, .location = TestHarness.bootstrap_location, .axis = .horizontal, .area = host(client).view.workbench() });
    try std.testing.expect(active.focusPane(TestHarness.bootstrap_pane));

    try notification_flow.publishNow(client, .{
        .title = "Ready",
        .message = "Open pane",
        .target = .{ .focus_pane = second_pane },
    });
    const item = client.model.notificationSnapshot().itemAt(0).?;
    const notification_id = item.id;
    const visible_at_ns = item.transition_updated_ns + transition_duration_ns_module;
    _ = client.model.advanceNotifications(visible_at_ns);

    const composed = try host(client).presenter.compositor.render(.{
        .model = active,
        .screen = &host(client).presenter.screen,
        .input = .{
            .area = host(client).view.workbench(),
            .palette = host(client).view.palette(),
        },
    });
    _ = active.commitPresentation(composed.commit);
    _ = try host(client).view.render(&host(client).presenter.screen, .{
        .model = active,
        .compositor = &host(client).presenter.compositor,
        .notifications = client.model.notificationSnapshot(),
        .force = true,
    });
    var click: ?term.Event.Mouse = null;
    for (host(client).view.hits.registered()) |entry| switch (entry.action) {
        .notification_activate => |id| {
            if (id != notification_id) {
                continue;
            }

            click = .{
                .x = entry.rect.x + 1,
                .y = entry.rect.y + 1,
                .kind = .press,
            };
            break;
        },
        else => {},
    };
    const notification_click = click orelse return error.MissingNotificationHit;
    const version_before_activation = client.model.version();
    var handler: InputHandler = .{ .client = client };

    try handler.mouse(notification_click);

    try std.testing.expectEqual(second_pane, active.layout.focused().?);
    try std.testing.expectEqual(
        version_before_activation.notifications + 1,
        client.model.version().notifications,
    );
    const version_after_activation = client.model.version();

    try handler.mouse(notification_click);

    try std.testing.expectEqualDeep(version_after_activation, client.model.version());
}

test "proxy status commits before announcement and presenter-owned projection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const pending_updates_before = host(client).presenter.pending_updates;

    var payload: [64]u8 = undefined;
    const enabled = try encodeProxyStatus_module(&payload, .{ .active = true, .scope = .wildcard, .system_trusted = false });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(enabled));

    try std.testing.expect(client.model.proxyTlsActive());
    try std.testing.expectEqual(version_before.proxy_status + 1, client.model.version().proxy_status);
    try std.testing.expectEqual(version_before.notifications + 1, client.model.version().notifications);
    try std.testing.expectEqual(version_before.proxy_status, host(client).presenter.presentation_state.observed.model.proxy_status);
    try std.testing.expectEqual(pending_updates_before, host(client).presenter.pending_updates);
    try std.testing.expectEqual(@as(u8, 1), client.model.notificationSnapshot().count);
    try std.testing.expectEqualStrings(
        "TLS interception active",
        client.model.notificationSnapshot().itemAt(0).?.title(),
    );

    _ = try server_messages.handleServerMessage(client, try decodeServer_module(enabled));

    try std.testing.expectEqual(version_before.proxy_status + 1, client.model.version().proxy_status);
    try std.testing.expectEqual(version_before.notifications + 1, client.model.version().notifications);
    try std.testing.expectEqual(pending_updates_before, host(client).presenter.pending_updates);
    try std.testing.expectEqual(@as(u8, 1), client.model.notificationSnapshot().count);

    try presentation_lifecycle.observe(client);
    const enabled_version = client.model.version();

    try std.testing.expectEqual(pending_updates_before + 1, host(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);
    try std.testing.expectEqual(
        enabled_version.proxy_status,
        host(client).presenter.presentation_state.prepared.model.proxy_status,
    );
    const badge_index = @as(usize, host(client).presenter.screen.front.w) - 2;
    try std.testing.expectEqualStrings("\u{26e8}", host(client).presenter.screen.front.cells[badge_index].text());
    try std.testing.expectEqualDeep(
        host(client).view.palette().red,
        host(client).presenter.screen.front.cells[badge_index].style.fg,
    );

    const pending_updates_after_enabled = host(client).presenter.pending_updates;
    const version_before_disabled = client.model.version();
    const disabled = try encodeProxyStatus_module(&payload, .{ .active = false, .scope = .exact, .system_trusted = false });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(disabled));

    try std.testing.expect(!client.model.proxyTlsActive());
    try std.testing.expectEqual(version_before_disabled.proxy_status + 1, client.model.version().proxy_status);
    try std.testing.expectEqual(version_before_disabled.notifications + 1, client.model.version().notifications);
    try std.testing.expectEqual(pending_updates_after_enabled, host(client).presenter.pending_updates);
    try std.testing.expectEqual(@as(u8, 2), client.model.notificationSnapshot().count);
    try std.testing.expectEqualStrings(
        "TLS interception stopped",
        client.model.notificationSnapshot().itemAt(0).?.title(),
    );

    try presentation_lifecycle.observe(client);
    const disabled_version = client.model.version();
    try harness.settleModelPresentation();

    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);
    try std.testing.expectEqual(
        disabled_version.proxy_status,
        host(client).presenter.presentation_state.prepared.model.proxy_status,
    );
    try std.testing.expect(!std.mem.eql(u8, "\u{26e8}", host(client).presenter.screen.front.cells[badge_index].text()));
}

test "system metrics commit before presenter-owned projection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const pending_updates_before = host(client).presenter.pending_updates;

    var payload: [64]u8 = undefined;
    const metrics = try encodeSystemMetrics_module(&payload, .{
        .revision = 7,
        .cpu_percent = 50,
        .memory_used_decigib = 10,
        .has_battery = true,
        .battery_percent = 80,
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(metrics));

    try std.testing.expectEqualDeep(SystemMetricsType{
        .runtime_revision = 7,
        .cpu_percent = 50,
        .memory_used_decigib = 10,
        .battery_percent = 80,
    }, client.model.systemMetrics().?);
    try std.testing.expectEqual(version_before.system_metrics + 1, client.model.version().system_metrics);
    try std.testing.expectEqual(pending_updates_before, host(client).presenter.pending_updates);
    try std.testing.expect(!host(client).view.dirty);

    _ = try server_messages.handleServerMessage(client, try decodeServer_module(metrics));
    try std.testing.expectEqual(version_before.system_metrics + 1, client.model.version().system_metrics);
    try std.testing.expectEqual(pending_updates_before, host(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before + 1, host(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);

    var bottom_text_buffer: [512]u8 = undefined;
    const sidebar = host(client).view.regions.sidebar;
    const contracted_bottom = host(client).view.regions.bottom;
    const contracted_text = try screenText(&host(client).presenter.screen, contracted_bottom, &bottom_text_buffer);

    try std.testing.expectEqual(sidebar.x + sidebar.w, contracted_bottom.x);
    try std.testing.expect(std.mem.indexOf(u8, contracted_text, " 50%") != null);

    _ = try client_actions.apply(client, .toggle_sidebar);
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();

    const expanded_bottom = host(client).view.regions.bottom;
    const expanded_text = try screenText(&host(client).presenter.screen, expanded_bottom, &bottom_text_buffer);

    try std.testing.expectEqual(@as(u16, 0), expanded_bottom.x);
    try std.testing.expectEqual(host(client).presenter.screen.front.w, expanded_bottom.w);
    try std.testing.expect(std.mem.indexOf(u8, expanded_text, " 50%") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded_text, " 1.0G") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded_text, "80%") != null);
}

fn screenText(screen: *const ScreenType, area: RectType, storage: *[512]u8) ![]const u8 {
    var len: usize = 0;
    for (area.x..area.x + area.w) |x| {
        const cell = screen.front.cells[@as(usize, area.y) * screen.front.w + x];
        const text = cell.text();
        if (len + text.len > storage.len) {
            return error.TestScreenTextTooLong;
        }

        @memcpy(storage[len..][0..text.len], text);
        len += text.len;
    }

    return storage[0..len];
}

test "workspace list snapshots commit before presenter-owned projection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const pending_updates_before = host(client).presenter.pending_updates;

    var payload: [512]u8 = undefined;
    const list = try encodeWorkspaceList_module(&payload, .{
        .revision = 7,
        .entries = &.{
            .{ .workspace = @enumFromInt(1), .name = "main", .path = "/work/main", .tab_count = 1 },
            .{ .workspace = @enumFromInt(2), .name = "api", .path = "/work/api", .tab_count = 2 },
        },
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(list));

    try std.testing.expect(client.model.knowsWorkspace(@enumFromInt(1)));
    try std.testing.expect(client.model.knowsWorkspace(@enumFromInt(2)));
    try std.testing.expectEqualStrings("/work/api", client.model.workspaceListSnapshot().pathAt(1));
    try std.testing.expectEqual(version_before.workspace_list + 1, client.model.version().workspace_list);
    try std.testing.expectEqual(pending_updates_before, host(client).presenter.pending_updates);
    try std.testing.expect(!host(client).view.dirty);

    _ = try server_messages.handleServerMessage(client, try decodeServer_module(list));
    try std.testing.expectEqual(version_before.workspace_list + 1, client.model.version().workspace_list);
    try std.testing.expectEqual(pending_updates_before, host(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before + 1, host(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);
    var found_second = false;
    for (0..host(client).presenter.screen.front.w) |x| {
        const action = host(client).view.hits.at(@intCast(x), 0) orelse continue;
        if (action == .select_workspace and action.select_workspace == @as(WorkspaceIdType, @enumFromInt(2))) {
            found_second = true;
            break;
        }
    }
    try std.testing.expect(found_second);
}

test "workspace position navigation resolves the committed client model" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};

    var payload: [512]u8 = undefined;
    const list = try encodeWorkspaceList_module(&payload, .{
        .revision = 1,
        .entries = &.{
            .{ .workspace = @enumFromInt(1), .name = "main", .path = "/work/main", .tab_count = 1 },
            .{ .workspace = @enumFromInt(2), .name = "api", .path = "/work/api", .tab_count = 1 },
        },
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(list));
    const pending_updates_before = host(client).presenter.pending_updates;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .{ .select_workspace = 1 });

    try std.testing.expect(client.model.workspaceLocation() == null);
    try std.testing.expectEqual(pending_updates_before, host(client).presenter.pending_updates);
    try harness.settle();

    var message_buffer: [256]u8 = undefined;
    var target: ?PaneTargetType = null;
    while (target == null) {
        switch (try harness.nextClientMessage(&message_buffer)) {
            .detach_pane => {},
            .open_pane => |open| target = open.target,
            else => return error.UnexpectedClientMessage,
        }
    }

    try std.testing.expectEqualDeep(
        PaneTargetType{ .workspace = @enumFromInt(2) },
        target.?,
    );
}

test "an agent snapshot replaces the sidebar replica" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    var payload: [512]u8 = undefined;
    const snapshot = try encodeAgentSnapshot_module(&payload, .{
        .revision = 1,
        .entries = &.{.{
            .pane_id = TestHarness.bootstrap_pane,
            .pane_generation = 1,
            .location = TestHarness.bootstrap_location,
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
    const pending_updates = host(harness.client).presenter.pending_updates;
    host(harness.client).view.sidebar.scroll = 7;
    _ = try server_messages.handleServerMessage(harness.client, try decodeServer_module(snapshot));
    const agent = harness.client.model.agentSnapshot().find(.{
        .pane_id = TestHarness.bootstrap_pane,
        .pane_generation = 1,
    }).?;
    try std.testing.expectEqualStrings("telar", agent.workspaceLabel());
    try std.testing.expectEqualStrings("test-2", agent.tabLabel());
    try std.testing.expectEqualStrings("Improve agent sidebar", agent.sessionTitle());
    try std.testing.expectEqualStrings("~/sandbox/telar", agent.cwdLabel());
    try std.testing.expectEqual(VersionType{ .agents = 1 }, harness.client.model.version());
    try std.testing.expectEqual(pending_updates, host(harness.client).presenter.pending_updates);

    try presentation_lifecycle.observe(harness.client);
    try harness.settleModelPresentation();

    try std.testing.expectEqual(@as(u16, 0), host(harness.client).view.sidebar.scroll);
    try std.testing.expectEqual(
        harness.client.model.version(),
        host(harness.client).presenter.presentation_state.prepared.model,
    );
}

test "sidebar animation commits model state before the presenter observes it" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    var payload: [512]u8 = undefined;
    const snapshot = try support.encodeTestingAgentSnapshot(&payload, 1, .working);
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(snapshot));
    const pending_updates = host(client).presenter.pending_updates;

    try std.testing.expect(client.sidebar_animation_scheduler.pending);
    try std.testing.expectEqual(@as(u8, 0), client.model.sidebarAnimationFrame());
    switch (try host(client).select.await()) {
        .sidebar_animation_tick => |result| {
            const change = (try sidebar_animations.handleTick(client, result)).?;

            try std.testing.expectEqual(@as(u8, 1), change.frame);
            try std.testing.expectEqual(@as(u64, 1), change.sidebar_animation_revision);
        },
        else => return error.UnexpectedEvent,
    }

    try std.testing.expect(client.sidebar_animation_scheduler.pending);
    try std.testing.expectEqual(VersionType{
        .agents = 1,
        .sidebar_animation = 1,
    }, client.model.version());
    try std.testing.expectEqual(@as(u8, 1), client.model.sidebarAnimationFrame());
    try std.testing.expectEqual(pending_updates, host(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates + 1, host(client).presenter.pending_updates);
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.observed.model);
}

test "agent snapshot transitions raise bounded presentation alerts only once" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    var payload: [512]u8 = undefined;

    const initial = try support.encodeTestingAgentSnapshot(&payload, 1, .ready);
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(initial));

    try std.testing.expectEqual(@as(u8, 0), client.model.notificationSnapshot().count);
    try std.testing.expectEqual(VersionType{ .agents = 1 }, client.model.version());

    const changed = try support.encodeTestingAgentSnapshot(&payload, 2, .blocked);
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(changed));
    const notification = client.model.notificationSnapshot().itemAt(0).?;

    try std.testing.expectEqual(VersionType{ .agents = 2, .notifications = 1 }, client.model.version());
    try std.testing.expectEqual(@as(u8, 1), client.model.notificationSnapshot().count);
    try std.testing.expectEqual(LevelType.warning, notification.level);
    try std.testing.expectEqualStrings("Agent needs input", notification.title());
    try std.testing.expectEqualStrings("Claude in pane 3 is waiting for input", notification.message());
    try std.testing.expectEqualDeep(
        NotificationsRootTarget{ .focus_pane = TestHarness.bootstrap_pane },
        notification.target,
    );

    const stale = try support.encodeTestingAgentSnapshot(&payload, 1, .failed);
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(stale));

    try std.testing.expectEqual(VersionType{ .agents = 2, .notifications = 1 }, client.model.version());
    try std.testing.expectEqual(@as(u8, 1), client.model.notificationSnapshot().count);
}

test "agent sounds validate exact identity against the client model" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    var payload: [512]u8 = undefined;
    const snapshot = try support.encodeTestingAgentSnapshot(&payload, 1, .ready);
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(snapshot));
    const version_before_sound = client.model.version();
    const pending_updates = host(client).presenter.pending_updates;

    const unknown = try encodeAgentSound_module(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .pane_generation = 2,
        .sound = .ready,
    });
    const stale = try agent_sounds.apply(client, (try decodeServer_module(unknown)).agent_sound);

    try std.testing.expectEqual(ApplicationAgentsAgentSoundOutcome.stale, stale);
    try std.testing.expect(!client.sound_playback.snapshot().active);

    const known = try encodeAgentSound_module(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .pane_generation = 1,
        .sound = .ready,
    });
    const accepted = try agent_sounds.apply(client, (try decodeServer_module(known)).agent_sound);

    try std.testing.expectEqual(ApplicationAgentsAgentSoundOutcome.accepted, accepted);
    try std.testing.expect(client.sound_playback.snapshot().active);

    const urgent = try encodeAgentSound_module(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .pane_generation = 1,
        .sound = .needs_input,
    });
    const queued = try agent_sounds.apply(client, (try decodeServer_module(urgent)).agent_sound);

    try std.testing.expectEqual(ApplicationAgentsAgentSoundOutcome.accepted, queued);
    try std.testing.expectEqual(AgentSoundType.needs_input, client.sound_playback.snapshot().queued.?);
    try std.testing.expectEqualDeep(version_before_sound, client.model.version());
    try std.testing.expectEqual(pending_updates, host(client).presenter.pending_updates);
}

test "agent sound completion releases a failed worker before scheduling its successor" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const version_before = client.model.version();
    const pending_updates = host(client).presenter.pending_updates;

    try std.testing.expectEqualDeep(
        playback_support.RequestOutcome{ .start = .ready },
        client.sound_playback.request(.ready),
    );
    try std.testing.expect(client.sound_playback.request(.needs_input) == .queued);

    try agent_sounds.handlePlayed(client, error.SoundUnavailable);

    try std.testing.expectEqual(SnapshotType{
        .configuration = .{},
        .active = true,
        .queued = null,
    }, client.sound_playback.snapshot());
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates, host(client).presenter.pending_updates);
}
