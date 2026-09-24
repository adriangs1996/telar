//! Client integration tests for notifications and agents.
const keyinput = @import("keyinput");

const pacing = @import("pacing");
const cellgrid = @import("cellgrid");
const data = @import("model");
const core = @import("telar-core");
const client_module = @import("telar-client");
const TestHarness = @import("TestHarness.zig");
const std = @import("std");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const host_inputs = @import("../input/host_inputs.zig");
const Screen = @import("../../presentation/terminal_screen.zig").Screen;
const support = @import("support.zig");

test "a failed request surfaces as a notification" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    try client.model.request_lifecycle.tracker.add(@enumFromInt(4), .{ .close_pane = .{
        .pane_id = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
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
        data.NotificationTarget{ .select_tab = TestHarness.bootstrap_location.tab_id },
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
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: core.RequestId = @enumFromInt(4);
    try client.model.request_lifecycle.tracker.add(request_id, .{
        .workspace_snapshot = TestHarness.bootstrap_location.workspace,
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
    var harness: TestHarness = undefined;
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
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const terminal = harness.terminal;
    const version_before = client.model.version();
    const pending_updates_before = terminal.presenter.pending_updates;
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
    try std.testing.expectEqual(pending_updates_before, terminal.presenter.pending_updates);
    try std.testing.expect(client.model.notification_scheduler.pending);
}

test "notification action delivers one correlated runtime request without model effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const terminal = harness.terminal;
    const request_id: core.RequestId = @enumFromInt(client.model.request_lifecycle.next_request_id);
    const version_before = client.model.version();
    const pending_updates_before = terminal.presenter.pending_updates;
    try client.model.to_runtime.push(
        .{
            .detach_pane = .{
                .pane_id = TestHarness.bootstrap_pane,
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
    try std.testing.expectEqual(pending_updates_before, terminal.presenter.pending_updates);
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
    try std.testing.expectEqual(pending_updates_before, terminal.presenter.pending_updates);
}

test "notification request rolls correlation back when transport is full" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const terminal = harness.terminal;
    while (client.model.to_runtime.hasCapacity()) {
        try client.model.to_runtime.push(.{
            .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane },
        });
    }
    const next_request_id = client.model.request_lifecycle.next_request_id;
    const version_before = client.model.version();
    const pending_updates_before = terminal.presenter.pending_updates;
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
    try std.testing.expectEqual(pending_updates_before, terminal.presenter.pending_updates);
}

test "notification timer commits lifecycle state before presenter observation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const terminal = harness.terminal;
    const now_ns = pacing.clock.monotonic(client.io);
    _ = try client_module.notifications.publishNotification(client, now_ns, .{
        .title = "Building",
        .message = "Lifecycle tick",
    });
    const pending_updates = terminal.presenter.pending_updates;

    try std.testing.expect(client.model.notification_scheduler.pending);
    switch (try support.receiveClient(terminal)) {
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
    try std.testing.expectEqual(pending_updates, terminal.presenter.pending_updates);

    try presentation_lifecycle.observe(terminal);

    try std.testing.expectEqual(pending_updates + 1, terminal.presenter.pending_updates);
    try std.testing.expectEqualDeep(client.model.version(), terminal.presenter.presentation_state.observed.model);
}

test "an unexpected notification delivery report is rejected without effects" {
    var harness: TestHarness = undefined;
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
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: core.RequestId = @enumFromInt(90);
    try client.model.request_lifecycle.tracker.add(request_id, .{ .move_tab = TestHarness.bootstrap_location });
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
    var harness: TestHarness = undefined;
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
    var harness: TestHarness = undefined;
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

test "toast activation commits by id before following its navigation target" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const active = client.model.tabs.active;
    const second_pane: core.PaneId = @enumFromInt(11);
    try data.pane_split.split(&client.model, active, .{ .existing_pane = TestHarness.bootstrap_pane, .new_pane = second_pane, .location = TestHarness.bootstrap_location, .axis = .horizontal, .area = terminal.view.workbench() });
    try std.testing.expect(client.model.tabs.layout[active].focusPane(TestHarness.bootstrap_pane));

    try client_module.notifications.publishNotificationNow(client, .{
        .title = "Ready",
        .message = "Open pane",
        .target = .{ .focus_pane = second_pane },
    });
    const item = client.model.notification_center.itemAt(0).?;
    const notification_id = item.id;
    const visible_at_ns = item.transition_updated_ns + data.notifications.transition_duration_ns;
    _ = data.notifications.advance(&client.model, visible_at_ns);

    const composed = try terminal.presenter.compositor.render(.{
        .model = &client.model,
        .tab = active,
        .screen = &terminal.presenter.screen,
        .input = .{
            .area = terminal.view.workbench(),
            .palette = terminal.view.palette(),
        },
    });
    _ = data.presentation_delivery.retire(&client.model, composed.commit);
    _ = try terminal.view.render(&terminal.presenter.screen, .{
        .model = &client.model,
        .tab = active,
        .compositor = &terminal.presenter.compositor,
        .notifications = &client.model.notification_center,
        .force = true,
    });
    var click: ?keyinput.Mouse = null;
    for (terminal.view.hits.registered()) |entry| switch (entry.action) {
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

    try host_inputs.mouse(terminal, notification_click);

    try std.testing.expectEqual(second_pane, client.model.tabs.layout[active].focused().?);
    try std.testing.expectEqual(
        version_before_activation.notifications + 1,
        client.model.version().notifications,
    );
    const version_after_activation = client.model.version();

    try host_inputs.mouse(terminal, notification_click);

    try std.testing.expectEqualDeep(version_after_activation, client.model.version());
}

test "proxy status commits before announcement and presenter-owned projection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const version_before = client.model.version();
    const pending_updates_before = terminal.presenter.pending_updates;

    var payload: [64]u8 = undefined;
    const enabled = try core.encodeProxyStatus(&payload, .{ .active = true, .scope = .wildcard, .system_trusted = false });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(enabled));

    try std.testing.expect(client.model.proxy_tls_active);
    try std.testing.expectEqual(version_before.proxy_status + 1, client.model.version().proxy_status);
    try std.testing.expectEqual(version_before.notifications + 1, client.model.version().notifications);
    try std.testing.expectEqual(version_before.proxy_status, terminal.presenter.presentation_state.observed.model.proxy_status);
    try std.testing.expectEqual(pending_updates_before, terminal.presenter.pending_updates);
    try std.testing.expectEqual(@as(u8, 1), client.model.notification_center.count);
    try std.testing.expectEqualStrings(
        "TLS interception active",
        client.model.notification_center.itemAt(0).?.title(),
    );

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(enabled));

    try std.testing.expectEqual(version_before.proxy_status + 1, client.model.version().proxy_status);
    try std.testing.expectEqual(version_before.notifications + 1, client.model.version().notifications);
    try std.testing.expectEqual(pending_updates_before, terminal.presenter.pending_updates);
    try std.testing.expectEqual(@as(u8, 1), client.model.notification_center.count);

    try presentation_lifecycle.observe(terminal);
    const enabled_version = client.model.version();

    try std.testing.expectEqual(pending_updates_before + 1, terminal.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), terminal.presenter.presentation_state.prepared.model);
    try std.testing.expectEqual(
        enabled_version.proxy_status,
        terminal.presenter.presentation_state.prepared.model.proxy_status,
    );
    const badge_index = @as(usize, terminal.presenter.screen.front.w) - 2;
    try std.testing.expectEqualStrings("\u{26e8}", terminal.presenter.screen.front.cells[badge_index].text());
    try std.testing.expectEqualDeep(
        terminal.view.palette().red,
        terminal.presenter.screen.front.cells[badge_index].style.fg,
    );

    const pending_updates_after_enabled = terminal.presenter.pending_updates;
    const version_before_disabled = client.model.version();
    const disabled = try core.encodeProxyStatus(&payload, .{ .active = false, .scope = .exact, .system_trusted = false });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(disabled));

    try std.testing.expect(!client.model.proxy_tls_active);
    try std.testing.expectEqual(version_before_disabled.proxy_status + 1, client.model.version().proxy_status);
    try std.testing.expectEqual(version_before_disabled.notifications + 1, client.model.version().notifications);
    try std.testing.expectEqual(pending_updates_after_enabled, terminal.presenter.pending_updates);
    try std.testing.expectEqual(@as(u8, 2), client.model.notification_center.count);
    try std.testing.expectEqualStrings(
        "TLS interception stopped",
        client.model.notification_center.itemAt(0).?.title(),
    );

    try presentation_lifecycle.observe(terminal);
    const disabled_version = client.model.version();
    try harness.settleModelPresentation();

    try std.testing.expectEqualDeep(client.model.version(), terminal.presenter.presentation_state.prepared.model);
    try std.testing.expectEqual(
        disabled_version.proxy_status,
        terminal.presenter.presentation_state.prepared.model.proxy_status,
    );
    try std.testing.expect(!std.mem.eql(u8, "\u{26e8}", terminal.presenter.screen.front.cells[badge_index].text()));
}

test "system metrics commit before presenter-owned projection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const version_before = client.model.version();
    const pending_updates_before = terminal.presenter.pending_updates;

    var payload: [64]u8 = undefined;
    const metrics = try core.encodeSystemMetrics(&payload, .{
        .revision = 7,
        .cpu_percent = 50,
        .memory_used_decigib = 10,
        .has_battery = true,
        .battery_percent = 80,
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(metrics));

    try std.testing.expectEqualDeep(data.SystemMetrics{
        .runtime_revision = 7,
        .cpu_percent = 50,
        .memory_used_decigib = 10,
        .battery_percent = 80,
    }, client.model.system_metrics.?);
    try std.testing.expectEqual(version_before.system_metrics + 1, client.model.version().system_metrics);
    try std.testing.expectEqual(pending_updates_before, terminal.presenter.pending_updates);
    try std.testing.expect(!terminal.view.dirty);

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(metrics));
    try std.testing.expectEqual(version_before.system_metrics + 1, client.model.version().system_metrics);
    try std.testing.expectEqual(pending_updates_before, terminal.presenter.pending_updates);

    try presentation_lifecycle.observe(terminal);

    try std.testing.expectEqual(pending_updates_before + 1, terminal.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), terminal.presenter.presentation_state.prepared.model);

    var bottom_text_buffer: [512]u8 = undefined;
    const sidebar = terminal.view.regions.sidebar;
    const contracted_bottom = terminal.view.regions.bottom;
    const contracted_text = try screenText(&terminal.presenter.screen, contracted_bottom, &bottom_text_buffer);

    try std.testing.expectEqual(sidebar.x + sidebar.w, contracted_bottom.x);
    try std.testing.expect(std.mem.indexOf(u8, contracted_text, " 50%") != null);

    _ = try client_module.actions.executeAction(client, .toggle_sidebar, .effect);
    try presentation_lifecycle.observe(terminal);
    try harness.settleModelPresentation();

    const expanded_bottom = terminal.view.regions.bottom;
    const expanded_text = try screenText(&terminal.presenter.screen, expanded_bottom, &bottom_text_buffer);

    try std.testing.expectEqual(@as(u16, 0), expanded_bottom.x);
    try std.testing.expectEqual(terminal.presenter.screen.front.w, expanded_bottom.w);
    try std.testing.expect(std.mem.indexOf(u8, expanded_text, " 50%") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded_text, " 1.0G") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded_text, "80%") != null);
}

fn screenText(screen: *const Screen, area: cellgrid.Rect, storage: *[512]u8) ![]const u8 {
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
    const terminal = harness.terminal;
    const version_before = client.model.version();
    const pending_updates_before = terminal.presenter.pending_updates;

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
    try std.testing.expectEqual(pending_updates_before, terminal.presenter.pending_updates);
    try std.testing.expect(!terminal.view.dirty);

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(list));
    try std.testing.expectEqual(version_before.workspace_list + 1, client.model.version().workspace_list);
    try std.testing.expectEqual(pending_updates_before, terminal.presenter.pending_updates);

    try presentation_lifecycle.observe(terminal);

    try std.testing.expectEqual(pending_updates_before + 1, terminal.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), terminal.presenter.presentation_state.prepared.model);
    var found_second = false;
    for (0..terminal.presenter.screen.front.w) |x| {
        const action = terminal.view.hits.at(@intCast(x), 0) orelse continue;
        if (action == .select_workspace and action.select_workspace == @as(core.WorkspaceId, @enumFromInt(2))) {
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
    const terminal = harness.terminal;
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
    const pending_updates_before = terminal.presenter.pending_updates;

    _ = try client_module.actions.executeAction(
        client,
        .{
            .select_workspace = 1,
        },
        .effect,
    );

    try std.testing.expect(client.model.workspace == null);
    try std.testing.expectEqual(pending_updates_before, terminal.presenter.pending_updates);
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
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    var payload: [512]u8 = undefined;
    const snapshot = try core.encodeAgentSnapshot(&payload, .{
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
    const pending_updates = harness.terminal.presenter.pending_updates;
    harness.terminal.view.sidebar.scroll = 7;
    _ = try client_module.runtime_messages.handleServerMessage(harness.client, try core.decodeServer(snapshot));
    const agent = harness.client.model.agent_snapshot.find(.{
        .pane_id = TestHarness.bootstrap_pane,
        .pane_generation = 1,
    }).?;
    try std.testing.expectEqualStrings("telar", agent.workspaceLabel());
    try std.testing.expectEqualStrings("test-2", agent.tabLabel());
    try std.testing.expectEqualStrings("Improve agent sidebar", agent.sessionTitle());
    try std.testing.expectEqualStrings("~/sandbox/telar", agent.cwdLabel());
    try std.testing.expectEqual(data.Version{ .agents = 1 }, harness.client.model.version());
    try std.testing.expectEqual(pending_updates, harness.terminal.presenter.pending_updates);

    try presentation_lifecycle.observe(harness.terminal);
    try harness.settleModelPresentation();

    try std.testing.expectEqual(@as(u16, 0), harness.terminal.view.sidebar.scroll);
    try std.testing.expectEqual(
        harness.client.model.version(),
        harness.terminal.presenter.presentation_state.prepared.model,
    );
}

test "sidebar animation commits model state before the presenter observes it" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const terminal = harness.terminal;
    var payload: [512]u8 = undefined;
    const snapshot = try support.encodeTestingAgentSnapshot(&payload, 1, .working);
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(snapshot));
    const pending_updates = terminal.presenter.pending_updates;

    try std.testing.expect(client.model.sidebar_animation_scheduler.pending);
    try std.testing.expectEqual(@as(u8, 0), client.model.sidebar_animation_frame);
    switch (try support.receiveClient(terminal)) {
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
    try std.testing.expectEqual(pending_updates, terminal.presenter.pending_updates);

    try presentation_lifecycle.observe(terminal);

    try std.testing.expectEqual(pending_updates + 1, terminal.presenter.pending_updates);
    try std.testing.expectEqualDeep(client.model.version(), terminal.presenter.presentation_state.observed.model);
}

test "agent snapshot transitions raise bounded presentation alerts only once" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    var payload: [512]u8 = undefined;

    const initial = try support.encodeTestingAgentSnapshot(&payload, 1, .ready);
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(initial));

    try std.testing.expectEqual(@as(u8, 0), client.model.notification_center.count);
    try std.testing.expectEqual(data.Version{ .agents = 1 }, client.model.version());

    const changed = try support.encodeTestingAgentSnapshot(&payload, 2, .blocked);
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(changed));
    const notification = client.model.notification_center.itemAt(0).?;

    try std.testing.expectEqual(data.Version{ .agents = 2, .notifications = 1 }, client.model.version());
    try std.testing.expectEqual(@as(u8, 1), client.model.notification_center.count);
    try std.testing.expectEqual(data.NotificationLevel.warning, notification.level);
    try std.testing.expectEqualStrings("Agent needs input", notification.title());
    try std.testing.expectEqualStrings("Claude in pane 3 is waiting for input", notification.message());
    try std.testing.expectEqualDeep(
        data.NotificationTarget{ .focus_pane = TestHarness.bootstrap_pane },
        notification.target,
    );

    const stale = try support.encodeTestingAgentSnapshot(&payload, 1, .failed);
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(stale));

    try std.testing.expectEqual(data.Version{ .agents = 2, .notifications = 1 }, client.model.version());
    try std.testing.expectEqual(@as(u8, 1), client.model.notification_center.count);
}

test "agent sounds validate exact identity against the client model" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const terminal = harness.terminal;
    var payload: [512]u8 = undefined;
    const snapshot = try support.encodeTestingAgentSnapshot(&payload, 1, .ready);
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(snapshot));
    const version_before_sound = client.model.version();
    const pending_updates = terminal.presenter.pending_updates;

    const unknown = try core.encodeAgentSound(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
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
        .pane_id = TestHarness.bootstrap_pane,
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
        .pane_id = TestHarness.bootstrap_pane,
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
    try std.testing.expectEqual(pending_updates, terminal.presenter.pending_updates);
}

test "agent sound completion releases a failed worker before scheduling its successor" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const terminal = harness.terminal;
    const version_before = client.model.version();
    const pending_updates = terminal.presenter.pending_updates;

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
    try std.testing.expectEqual(pending_updates, terminal.presenter.pending_updates);
}

test "a sound the host cannot start releases its token and does not poison a later request" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    var payload: [512]u8 = undefined;
    const initial = try support.encodeTestingAgentSnapshot(&payload, 1, .ready);
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(initial));
    try harness.deliverHostEffects();
    const message = try core.encodeAgentSound(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .pane_generation = 1,
        .sound = .ready,
    });

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(message));
    const job = client.to_workers.pop().?;
    try std.testing.expect(job == .sound);
    try client.failJob(job, error.SoundSchedulingFailed);

    try std.testing.expect(!client.model.sound_playback.snapshot().active);
    try std.testing.expect(client.model.sound_playback.snapshot().queued == null);
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(message));
    try std.testing.expect(client.model.sound_playback.snapshot().active);
}

test "agent snapshot limits alert publication while retaining every canonical status change" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    var entries: [data.notifications.max_items + 2]core.AgentSnapshotEntry = undefined;
    for (&entries, 0..) |*entry, index| {
        entry.* = .{
            .pane_id = @enumFromInt(index + 1),
            .pane_generation = 1,
            .location = TestHarness.bootstrap_location,
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
    for (&entries) |*entry| {
        entry.status = .blocked;
        entry.sequence = 2;
    }
    const changed = try core.encodeAgentSnapshot(&payload, .{ .revision = 2, .entries = &entries });

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(changed));

    try std.testing.expectEqual(@as(u64, data.notifications.max_items), client.model.version().notifications);
    try std.testing.expectEqual(data.notifications.max_items, client.model.notification_center.count);
    try std.testing.expectEqual(entries.len, client.model.agent_snapshot.count);
    for (entries) |entry| {
        try std.testing.expectEqual(entry.status, client.model.agent_snapshot.find(.{ .pane_id = entry.pane_id, .pane_generation = entry.pane_generation }).?.status);
    }
    const version = client.model.version();
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(changed));
    try std.testing.expectEqualDeep(version, client.model.version());
}

test "agent alert host failure preserves the canonical snapshot and owned notification without replay" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    var payload: [512]u8 = undefined;
    const initial = try support.encodeTestingAgentSnapshot(&payload, 1, .ready);
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(initial));
    client.model.config.notification_delivery = .terminal;
    try fillHostEffects(client);
    const changed = try support.encodeTestingAgentSnapshot(&payload, 2, .blocked);

    try std.testing.expectError(error.HostEffectsFull, client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(changed)));

    try std.testing.expectEqual(data.HostEffects.capacity, client.model.to_host.count);
    try std.testing.expectEqual(@as(u64, 2), client.model.agent_snapshot.revision);
    try std.testing.expectEqual(data.NotificationLevel.warning, client.model.notification_center.itemAt(0).?.level);
    try std.testing.expect(client.model.notification_scheduler.pending);
    const version = client.model.version();
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(changed));
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(data.HostEffects.capacity, client.model.to_host.count);
}

test "attachment rejection consumes correlation but does not notify when recovery delivery fails" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    client.model.panes.find(TestHarness.bootstrap_pane).?.attached = false;
    const request_id = try client.model.request_lifecycle.nextId();
    try client.model.request_lifecycle.tracker.add(request_id, .{ .attach_pane = .{
        .pane_id = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
    } });
    while (client.model.to_runtime.hasCapacity()) {
        try client.model.to_runtime.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
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

test "request failure retains canonical recovery when host notification delivery fails" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};
    client.model.panes.find(TestHarness.bootstrap_pane).?.attached = false;
    const request_id = try client.model.request_lifecycle.nextId();
    try client.model.request_lifecycle.tracker.add(request_id, .{ .attach_pane = .{
        .pane_id = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
    } });
    client.model.config.notification_delivery = .terminal;
    try fillHostEffects(client);
    var payload: [256]u8 = undefined;
    const failed = try core.encodeRequestFailed(&payload, .{
        .request_id = request_id,
        .code = .pane_not_found,
        .message = "pane disappeared",
    });

    try std.testing.expectError(error.HostEffectsFull, client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(failed)));

    try std.testing.expectEqual(data.HostEffects.capacity, client.model.to_host.count);
    try std.testing.expect(client.model.request_lifecycle.tracker.has(.tab_snapshot));
    try std.testing.expectEqual(@as(u8, 1), client.model.notification_center.count);
    try std.testing.expectEqualStrings("pane disappeared", client.model.notification_center.itemAt(0).?.message());
    try std.testing.expectError(error.UnexpectedRequestFailure, client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(failed)));
    try std.testing.expectEqual(data.HostEffects.capacity, client.model.to_host.count);
    try harness.settle();
    var outgoing: [256]u8 = undefined;
    const recovery = try harness.nextClientMessage(&outgoing);
    try std.testing.expect(recovery == .request_tab_snapshot);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, recovery.request_tab_snapshot.location);
}

/// Leaves no room for another host request.
fn fillHostEffects(client: *client_module.Client) !void {
    while (client.model.to_host.count < data.HostEffects.capacity) {
        try client.model.to_host.push(.{ .terminal_notification = .{} });
    }
}
