//! Client integration tests for notifications and agents.

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
    const failed = try schema.encodeRequestFailed(&payload, .{
        .request_id = @enumFromInt(4),
        .code = .pane_not_found,
        .message = "no such pane",
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(failed));
    try harness.settle();
    const notification = client.model.notificationSnapshot().itemAt(0).?;

    try std.testing.expect(client.notification_scheduler.pending);
    try std.testing.expectEqualStrings("Could not close pane", notification.title());
    try std.testing.expectEqualStrings("no such pane", notification.message());
    try std.testing.expectEqualDeep(
        notifications.Target{ .select_tab = TestHarness.bootstrap_location.tab_id },
        notification.target,
    );

    const unknown = try schema.encodeRequestFailed(&payload, .{
        .request_id = @enumFromInt(99),
        .code = .pane_not_found,
        .message = "no such request",
    });
    try std.testing.expectError(
        error.UnexpectedRequestFailure,
        server_messages.handleServerMessage(client, try schema.decodeServer(unknown)),
    );
}

test "a failed snapshot request is fatal after consuming its continuation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: schema.RequestId = @enumFromInt(4);
    try client.request_lifecycle.tracker.add(request_id, .{
        .workspace_snapshot = TestHarness.bootstrap_location.workspace,
    });

    var payload: [256]u8 = undefined;
    const failed = try schema.encodeRequestFailed(&payload, .{
        .request_id = request_id,
        .code = .workspace_not_found,
        .message = "workspace disappeared",
    });

    try std.testing.expectError(
        error.RuntimeRequestFailed,
        server_messages.handleServerMessage(client, try schema.decodeServer(failed)),
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
    const pending_updates_before = client.presenter.pending_updates;
    var payload: [512]u8 = undefined;
    const encoded = try schema.encodeNotification(&payload, .{
        .level = .warning,
        .duration_ms = 2500,
        .target = .{ .tab = @enumFromInt(3) },
        .title = "Agent waiting",
        .message = "Review its question",
    });

    const publication = try notification_flow.applyRuntime(
        client,
        (try schema.decodeServer(encoded)).notification,
    );
    @memset(&payload, 'x');

    const item = client.model.notificationSnapshot().itemAt(0).?;
    try std.testing.expectEqual(item.id, publication.id);
    try std.testing.expectEqual(version_before.notifications + 1, publication.notifications_revision);
    try std.testing.expectEqual(notifications.Level.warning, item.level);
    try std.testing.expectEqual(
        notifications.Target{ .select_tab = @enumFromInt(3) },
        item.target,
    );
    try std.testing.expectEqualStrings("Agent waiting", item.title());
    try std.testing.expectEqualStrings("Review its question", item.message());
    try std.testing.expectEqual(
        notifications.transition_duration_ns + 2500 * std.time.ns_per_ms,
        item.expires_at_ns - item.transition_updated_ns,
    );
    try std.testing.expectEqual(version_before.notifications + 1, client.model.version().notifications);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expect(client.notification_scheduler.pending);
}

test "notification action delivers one correlated runtime request without model effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: schema.RequestId = @enumFromInt(client.request_lifecycle.next_request_id);
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    try runtime_transport.enqueue(client, .{
        .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane },
    });
    var notification = try input_capability.action.Notification.init(
        .warning,
        2500,
        .{ .tab = @enumFromInt(3) },
        "Agent waiting",
        "Review its question",
    );

    try std.testing.expectEqual(
        keybind.Control.continue_routing,
        try client_actions.apply(client, .{ .notification = notification }),
    );

    try std.testing.expect(request_lifecycle.has(client, .notification));
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    @memset(&notification.title_bytes, 'x');
    @memset(&notification.message_bytes, 'y');

    try harness.settle();
    var message_buffer: [512]u8 = undefined;
    const first = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(first == .detach_pane);
    const message = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(message == .show_notification);
    try std.testing.expectEqual(request_id, message.show_notification.request_id);
    try std.testing.expectEqual(schema.NotificationLevel.warning, message.show_notification.notification.level);
    try std.testing.expectEqual(@as(u32, 2500), message.show_notification.notification.duration_ms);
    try std.testing.expectEqualDeep(
        schema.NotificationTarget{ .tab = @enumFromInt(3) },
        message.show_notification.notification.target,
    );
    try std.testing.expectEqualStrings("Agent waiting", message.show_notification.notification.title);
    try std.testing.expectEqualStrings("Review its question", message.show_notification.notification.message);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
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
    const pending_updates_before = client.presenter.pending_updates;
    const notification = try input_capability.action.Notification.init(
        .info,
        schema.default_notification_duration_ms,
        .none,
        "Build complete",
        "Review the output",
    );

    try std.testing.expectError(
        error.ClientOutboxFull,
        notification_flow.requestDelivery(client, &notification),
    );

    try std.testing.expectEqual(next_request_id + 1, client.request_lifecycle.next_request_id);
    try std.testing.expect(client.request_lifecycle.tracker.isEmpty());
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
}

test "notification timer commits lifecycle state before presenter observation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const now_ns = client_clock.monotonic(client.io);
    _ = try notification_flow.publish(client, now_ns, .{
        .title = "Building",
        .message = "Lifecycle tick",
    });
    const pending_updates = client.presenter.pending_updates;

    try std.testing.expect(client.notification_scheduler.pending);
    switch (try client.select.await()) {
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
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates + 1, client.presenter.pending_updates);
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.observed_model_version);
}

test "an unexpected notification delivery report is rejected without effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const version_before = client.model.version();
    const shown: schema.NotificationShown = .{
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
    const request_id: schema.RequestId = @enumFromInt(90);
    try client.request_lifecycle.tracker.add(request_id, .{ .move_tab = TestHarness.bootstrap_location });
    const shown: schema.NotificationShown = .{
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
    const request_id: schema.RequestId = @enumFromInt(90);
    const version_before = client.model.version();
    try client.request_lifecycle.tracker.add(request_id, .notification);

    try std.testing.expectEqual(
        notification_flow.DeliveryOutcome.delivered,
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
    const notification = try schema.encodeNotification(&payload, .{ .title = "hello" });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(notification));
    try std.testing.expect(client.notification_scheduler.pending);
    const version_after_runtime = client.model.version();

    try client.request_lifecycle.tracker.add(@enumFromInt(2), .notification);
    const shown = try schema.encodeNotificationShown(&payload, .{
        .request_id = @enumFromInt(2),
        .delivered_clients = 0,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(shown));
    const snapshot = client.model.notificationSnapshot();

    try std.testing.expectEqual(version_after_runtime.notifications + 1, client.model.version().notifications);
    try std.testing.expectEqual(@as(u8, 2), snapshot.count);
    try std.testing.expectEqualStrings("Notification not delivered", snapshot.itemAt(0).?.title());
    try std.testing.expectEqualStrings(
        "No connected client could accept the notification",
        snapshot.itemAt(0).?.message(),
    );
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);

    const unexpected = try schema.encodeNotificationShown(&payload, .{
        .request_id = @enumFromInt(9),
        .delivered_clients = 1,
    });
    try std.testing.expectError(
        error.UnexpectedNotificationReply,
        server_messages.handleServerMessage(client, try schema.decodeServer(unexpected)),
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
    const second_pane: schema.PaneId = @enumFromInt(11);
    try active.split(
        TestHarness.bootstrap_pane,
        second_pane,
        TestHarness.bootstrap_location,
        .horizontal,
        client.view.workbench(),
    );
    try std.testing.expect(active.focusPane(TestHarness.bootstrap_pane));

    try notification_flow.publishNow(client, .{
        .title = "Ready",
        .message = "Open pane",
        .target = .{ .focus_pane = second_pane },
    });
    const item = client.model.notificationSnapshot().itemAt(0).?;
    const notification_id = item.id;
    const visible_at_ns = item.transition_updated_ns + notifications.transition_duration_ns;
    _ = client.model.advanceNotifications(visible_at_ns);

    const composed = try client.presenter.compositor.render(.{
        .model = active,
        .screen = &client.presenter.screen,
        .input = .{
            .area = client.view.workbench(),
            .palette = client.view.palette(),
        },
    });
    active.commitPresentation(composed.commit);
    _ = try client.view.render(&client.presenter.screen, .{
        .model = active,
        .compositor = &client.presenter.compositor,
        .notifications = client.model.notificationSnapshot(),
        .force = true,
    });
    var click: ?term.Event.Mouse = null;
    for (client.view.hits.registered()) |entry| switch (entry.action) {
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
    const pending_updates_before = client.presenter.pending_updates;

    var payload: [64]u8 = undefined;
    const enabled = try schema.encodeProxyStatus(&payload, .{ .active = true });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(enabled));

    try std.testing.expect(client.model.proxyTlsActive());
    try std.testing.expectEqual(version_before.proxy_status + 1, client.model.version().proxy_status);
    try std.testing.expectEqual(version_before.notifications + 1, client.model.version().notifications);
    try std.testing.expectEqual(version_before.proxy_status, client.presenter.observed_model_version.proxy_status);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(u8, 1), client.model.notificationSnapshot().count);
    try std.testing.expectEqualStrings(
        "TLS interception active",
        client.model.notificationSnapshot().itemAt(0).?.title(),
    );

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(enabled));

    try std.testing.expectEqual(version_before.proxy_status + 1, client.model.version().proxy_status);
    try std.testing.expectEqual(version_before.notifications + 1, client.model.version().notifications);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(u8, 1), client.model.notificationSnapshot().count);

    try presentation_lifecycle.observe(client);
    const enabled_version = client.model.version();

    try std.testing.expectEqual(pending_updates_before + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
    try std.testing.expectEqual(
        enabled_version.proxy_status,
        client.presenter.presented_model_version.proxy_status,
    );
    const badge_index = @as(usize, client.presenter.screen.front.w) - 2;
    try std.testing.expectEqualStrings("\u{26e8}", client.presenter.screen.front.cells[badge_index].text());

    const pending_updates_after_enabled = client.presenter.pending_updates;
    const version_before_disabled = client.model.version();
    const disabled = try schema.encodeProxyStatus(&payload, .{ .active = false });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(disabled));

    try std.testing.expect(!client.model.proxyTlsActive());
    try std.testing.expectEqual(version_before_disabled.proxy_status + 1, client.model.version().proxy_status);
    try std.testing.expectEqual(version_before_disabled.notifications + 1, client.model.version().notifications);
    try std.testing.expectEqual(pending_updates_after_enabled, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(u8, 2), client.model.notificationSnapshot().count);
    try std.testing.expectEqualStrings(
        "TLS interception stopped",
        client.model.notificationSnapshot().itemAt(0).?.title(),
    );

    try presentation_lifecycle.observe(client);
    const disabled_version = client.model.version();
    try harness.settleModelPresentation();

    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
    try std.testing.expectEqual(
        disabled_version.proxy_status,
        client.presenter.presented_model_version.proxy_status,
    );
    try std.testing.expect(!std.mem.eql(u8, "\u{26e8}", client.presenter.screen.front.cells[badge_index].text()));
}

test "system metrics commit before presenter-owned projection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;

    var payload: [64]u8 = undefined;
    const metrics = try schema.encodeSystemMetrics(&payload, .{
        .revision = 7,
        .cpu_percent = 50,
        .memory_used_decigib = 10,
        .has_battery = true,
        .battery_percent = 80,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(metrics));

    try std.testing.expectEqualDeep(client_model.SystemMetrics{
        .runtime_revision = 7,
        .cpu_percent = 50,
        .memory_used_decigib = 10,
        .battery_percent = 80,
    }, client.model.systemMetrics().?);
    try std.testing.expectEqual(version_before.system_metrics + 1, client.model.version().system_metrics);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expect(!client.view.dirty);

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(metrics));
    try std.testing.expectEqual(version_before.system_metrics + 1, client.model.version().system_metrics);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    var bottom_text_buffer: [512]u8 = undefined;
    const sidebar = client.view.regions.sidebar;
    const contracted_bottom = client.view.regions.bottom;
    const contracted_text = try screenText(&client.presenter.screen, contracted_bottom, &bottom_text_buffer);

    try std.testing.expectEqual(sidebar.x + sidebar.w, contracted_bottom.x);
    try std.testing.expect(std.mem.indexOf(u8, contracted_text, " 50%") != null);

    _ = try client_actions.apply(client, .toggle_sidebar);
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();

    const expanded_bottom = client.view.regions.bottom;
    const expanded_text = try screenText(&client.presenter.screen, expanded_bottom, &bottom_text_buffer);

    try std.testing.expectEqual(@as(u16, 0), expanded_bottom.x);
    try std.testing.expectEqual(client.presenter.screen.front.w, expanded_bottom.w);
    try std.testing.expect(std.mem.indexOf(u8, expanded_text, " 50%") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded_text, " 1.0G") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded_text, "80%") != null);
}

fn screenText(screen: *const term.Screen, area: core.ui.Rect, storage: *[512]u8) ![]const u8 {
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
    const pending_updates_before = client.presenter.pending_updates;

    var payload: [512]u8 = undefined;
    const list = try schema.encodeWorkspaceList(&payload, .{
        .revision = 7,
        .entries = &.{
            .{ .workspace = @enumFromInt(1), .name = "main", .path = "/work/main", .tab_count = 1 },
            .{ .workspace = @enumFromInt(2), .name = "api", .path = "/work/api", .tab_count = 2 },
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(list));

    try std.testing.expect(client.model.knowsWorkspace(@enumFromInt(1)));
    try std.testing.expect(client.model.knowsWorkspace(@enumFromInt(2)));
    try std.testing.expectEqualStrings("/work/api", client.model.workspaceListSnapshot().pathAt(1));
    try std.testing.expectEqual(version_before.workspace_list + 1, client.model.version().workspace_list);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expect(!client.view.dirty);

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(list));
    try std.testing.expectEqual(version_before.workspace_list + 1, client.model.version().workspace_list);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
    var found_second = false;
    for (0..client.presenter.screen.front.w) |x| {
        const action = client.view.hits.at(@intCast(x), 0) orelse continue;
        if (action == .select_workspace and action.select_workspace == @as(schema.WorkspaceId, @enumFromInt(2))) {
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
    const list = try schema.encodeWorkspaceList(&payload, .{
        .revision = 1,
        .entries = &.{
            .{ .workspace = @enumFromInt(1), .name = "main", .path = "/work/main", .tab_count = 1 },
            .{ .workspace = @enumFromInt(2), .name = "api", .path = "/work/api", .tab_count = 1 },
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(list));
    const pending_updates_before = client.presenter.pending_updates;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .{ .select_workspace = 1 });

    try std.testing.expect(client.model.workspaceLocation() == null);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try harness.settle();

    var message_buffer: [256]u8 = undefined;
    var target: ?schema.PaneTarget = null;
    while (target == null) {
        switch (try harness.nextClientMessage(&message_buffer)) {
            .detach_pane => {},
            .open_pane => |open| target = open.target,
            else => return error.UnexpectedClientMessage,
        }
    }

    try std.testing.expectEqualDeep(
        schema.PaneTarget{ .workspace = @enumFromInt(2) },
        target.?,
    );
}

test "an agent snapshot replaces the sidebar replica" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    var payload: [512]u8 = undefined;
    const snapshot = try schema.encodeAgentSnapshot(&payload, .{
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
    const pending_updates = harness.client.presenter.pending_updates;
    harness.client.view.sidebar.scroll = 7;
    _ = try server_messages.handleServerMessage(harness.client, try schema.decodeServer(snapshot));
    const agent = harness.client.model.agentSnapshot().find(.{
        .pane_id = TestHarness.bootstrap_pane,
        .pane_generation = 1,
    }).?;
    try std.testing.expectEqualStrings("telar", agent.workspaceLabel());
    try std.testing.expectEqualStrings("test-2", agent.tabLabel());
    try std.testing.expectEqualStrings("Improve agent sidebar", agent.sessionTitle());
    try std.testing.expectEqualStrings("~/sandbox/telar", agent.cwdLabel());
    try std.testing.expectEqual(client_model.Version{ .agents = 1 }, harness.client.model.version());
    try std.testing.expectEqual(pending_updates, harness.client.presenter.pending_updates);

    try presentation_lifecycle.observe(harness.client);
    try harness.settleModelPresentation();

    try std.testing.expectEqual(@as(u16, 0), harness.client.view.sidebar.scroll);
    try std.testing.expectEqual(
        harness.client.model.version(),
        harness.client.presenter.presented_model_version,
    );
}

test "sidebar animation commits model state before the presenter observes it" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    var payload: [512]u8 = undefined;
    const snapshot = try encodeTestingAgentSnapshot(&payload, 1, .working);
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(snapshot));
    const pending_updates = client.presenter.pending_updates;

    try std.testing.expect(client.sidebar_animation_scheduler.pending);
    try std.testing.expectEqual(@as(u8, 0), client.model.sidebarAnimationFrame());
    switch (try client.select.await()) {
        .sidebar_animation_tick => |result| {
            const change = (try sidebar_animations.handleTick(client, result)).?;

            try std.testing.expectEqual(@as(u8, 1), change.frame);
            try std.testing.expectEqual(@as(u64, 1), change.sidebar_animation_revision);
        },
        else => return error.UnexpectedEvent,
    }

    try std.testing.expect(client.sidebar_animation_scheduler.pending);
    try std.testing.expectEqual(client_model.Version{
        .agents = 1,
        .sidebar_animation = 1,
    }, client.model.version());
    try std.testing.expectEqual(@as(u8, 1), client.model.sidebarAnimationFrame());
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates + 1, client.presenter.pending_updates);
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.observed_model_version);
}

test "agent snapshot transitions raise bounded presentation alerts only once" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    var payload: [512]u8 = undefined;

    const initial = try encodeTestingAgentSnapshot(&payload, 1, .ready);
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(initial));

    try std.testing.expectEqual(@as(u8, 0), client.model.notificationSnapshot().count);
    try std.testing.expectEqual(client_model.Version{ .agents = 1 }, client.model.version());

    const changed = try encodeTestingAgentSnapshot(&payload, 2, .blocked);
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(changed));
    const notification = client.model.notificationSnapshot().itemAt(0).?;

    try std.testing.expectEqual(client_model.Version{ .agents = 2, .notifications = 1 }, client.model.version());
    try std.testing.expectEqual(@as(u8, 1), client.model.notificationSnapshot().count);
    try std.testing.expectEqual(notifications.Level.warning, notification.level);
    try std.testing.expectEqualStrings("Agent needs input", notification.title());
    try std.testing.expectEqualStrings("Claude in pane 3 is waiting for input", notification.message());
    try std.testing.expectEqualDeep(
        notifications.Target{ .focus_pane = TestHarness.bootstrap_pane },
        notification.target,
    );

    const stale = try encodeTestingAgentSnapshot(&payload, 1, .failed);
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(stale));

    try std.testing.expectEqual(client_model.Version{ .agents = 2, .notifications = 1 }, client.model.version());
    try std.testing.expectEqual(@as(u8, 1), client.model.notificationSnapshot().count);
}

test "agent sounds validate exact identity against the client model" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    var payload: [512]u8 = undefined;
    const snapshot = try encodeTestingAgentSnapshot(&payload, 1, .ready);
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(snapshot));
    const version_before_sound = client.model.version();
    const pending_updates = client.presenter.pending_updates;

    const unknown = try schema.encodeAgentSound(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .pane_generation = 2,
        .sound = .ready,
    });
    const stale = try agent_sounds.apply(client, (try schema.decodeServer(unknown)).agent_sound);

    try std.testing.expectEqual(agent_sounds.Outcome.stale, stale);
    try std.testing.expect(!client.sound_playback.snapshot().active);

    const known = try schema.encodeAgentSound(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .pane_generation = 1,
        .sound = .ready,
    });
    const accepted = try agent_sounds.apply(client, (try schema.decodeServer(known)).agent_sound);

    try std.testing.expectEqual(agent_sounds.Outcome.accepted, accepted);
    try std.testing.expect(client.sound_playback.snapshot().active);

    const urgent = try schema.encodeAgentSound(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .pane_generation = 1,
        .sound = .needs_input,
    });
    const queued = try agent_sounds.apply(client, (try schema.decodeServer(urgent)).agent_sound);

    try std.testing.expectEqual(agent_sounds.Outcome.accepted, queued);
    try std.testing.expectEqual(schema.AgentSound.needs_input, client.sound_playback.snapshot().queued.?);
    try std.testing.expectEqualDeep(version_before_sound, client.model.version());
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);
}

test "agent sound completion releases a failed worker before scheduling its successor" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const version_before = client.model.version();
    const pending_updates = client.presenter.pending_updates;

    try std.testing.expectEqualDeep(
        sound_capability.RequestOutcome{ .start = .ready },
        client.sound_playback.request(.ready),
    );
    try std.testing.expect(client.sound_playback.request(.needs_input) == .queued);

    try agent_sounds.handlePlayed(client, error.SoundUnavailable);

    try std.testing.expectEqual(sound_capability.Snapshot{
        .configuration = .{},
        .active = true,
        .queued = null,
    }, client.sound_playback.snapshot());
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);
}
