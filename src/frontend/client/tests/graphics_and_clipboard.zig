//! Client integration tests for graphics and clipboard.

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

test "a graphics revision break requests a graphics snapshot" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;

    var payload: [256]u8 = undefined;
    const begin = try schema.encodeGraphicsSnapshot(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 8,
        .phase = .begin,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(begin));
    const image = try schema.encodeGraphicsImage(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 9,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(image));
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .request_graphics_snapshot);
}

test "pane graphics commit their cell fallback before presenter observation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try client.model.observeHostCapability(.{ .kitty_graphics = .unsupported });
    const version_before = client.model.version();
    const pending_before = client.presenter.pending_updates;

    var payload: [256]u8 = undefined;
    const encoded = try schema.encodeGraphicsImage(&payload, .{
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
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(encoded));

    var committed = version_before;
    committed.pane_graphics += 1;
    try std.testing.expectEqualDeep(committed, client.model.version());
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.graphics_placeholder);
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_before + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(committed, client.presenter.presented_model_version);
}

test "presenter observes physical graphics without a semantic fallback" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try client.model.observeHostCapability(.{ .kitty_graphics = .supported });
    const version_before = client.model.version();
    const pending_before = client.presenter.pending_updates;

    var payload: [256]u8 = undefined;
    const encoded = try schema.encodeGraphicsImage(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 5,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(encoded));

    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(@as(u64, 1), client.graphics_store.ingressVersion());
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_before + 1, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(u64, 1), client.presenter.observed_graphics_ingress);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(@as(u64, 1), client.presenter.presented_graphics_ingress);

    const pending_after = client.presenter.pending_updates;
    const stale = try schema.encodeGraphicsDeleteImage(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 4,
        .key = .{ .image_id = 1, .generation = 1 },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(stale));
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(@as(u64, 1), client.graphics_store.ingressVersion());
    try std.testing.expectEqual(pending_after, client.presenter.pending_updates);
}

test "shared graphics mapping failure downgrades before resynchronizing" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();

    var payload: [256]u8 = undefined;
    const encoded = try schema.encodeGraphicsSharedImage(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 1,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        },
        .name = try core.graphics.ShmName.init("/telar-missing"),
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(encoded));
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const downgrade = try harness.nextClientMessage(&buffer);
    const recovery = try harness.nextClientMessage(&buffer);
    try std.testing.expect(downgrade == .configure_graphics);
    try std.testing.expect(!downgrade.configure_graphics.shared);
    try std.testing.expect(recovery == .request_graphics_snapshot);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, recovery.request_graphics_snapshot.pane_id);
    try std.testing.expectEqual(@as(u64, 0), client.graphics_store.ingressVersion());
    try std.testing.expectEqualDeep(version_before, client.model.version());
}

test "runtime stopping and stray history results" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    var payload: [128]u8 = undefined;
    const stopping = try schema.encodeRuntimeStopping(&payload);
    try std.testing.expectEqual(
        @as(?u8, 0),
        try server_messages.handleServerMessage(harness.client, try schema.decodeServer(stopping)),
    );

    const history = try schema.encodeHistoryResults(&payload, .{
        .request_id = @enumFromInt(2),
        .entries = &.{},
    });
    try std.testing.expectError(
        error.UnexpectedHistoryResults,
        server_messages.handleServerMessage(harness.client, try schema.decodeServer(history)),
    );
}

test "a pane clipboard write reaches the host terminal" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    const before = harness.sink.fullCount();
    var payload: [128]u8 = undefined;
    const clipboard = try schema.encodePaneClipboard(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .bytes = "copied",
    });
    _ = try server_messages.handleServerMessage(harness.client, try schema.decodeServer(clipboard));

    try std.testing.expectEqual(
        @as(u64, "\x1b]52;c;Y29waWVk\x07".len),
        harness.sink.fullCount() - before,
    );
}

test "an invalid pane clipboard writes no host bytes" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const before = harness.sink.fullCount();

    try std.testing.expectError(error.UnexpectedPane, pane_clipboards.apply(harness.client, .{
        .pane_id = .invalid,
        .bytes = "rejected",
    }));

    try std.testing.expectEqual(before, harness.sink.fullCount());
}
