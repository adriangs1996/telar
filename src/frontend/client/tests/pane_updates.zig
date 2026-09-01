//! Client integration tests for pane updates.

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

test "a patch against an unknown base requests a fresh snapshot" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version = client.model.version();
    const pending_updates = client.presenter.pending_updates;
    const frames = client.telemetry.metrics.frames;

    var payload: [512]u8 = undefined;
    const patch = try schema.encodePaneFrame(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .frame_id = 5,
        .base_frame_id = 4,
        .cols = 40,
        .rows = 10,
        .scroll = .{ .total_rows = 10, .offset = 0 },
        .spans = &.{},
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(patch));
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);
    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);
    if (comptime core.diagnostics.enabled) {
        try std.testing.expectEqual(frames, client.telemetry.metrics.frames);
    }

    try harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .request_snapshot);
    try std.testing.expectEqual(@as(u64, 0), message.request_snapshot.known_frame_id);

    // A full snapshot must carry exactly one span covering the whole grid.
    const blank: core.ui.Cell = .{};
    const cells: [4]core.ui.Cell = @splat(blank);
    try client.graphics_store.setPaneVisible(TestHarness.bootstrap_pane, false);
    const snapshot = try schema.encodePaneFrame(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .frame_id = 5,
        .base_frame_id = 0,
        .cols = 2,
        .rows = 2,
        .scroll = .{ .total_rows = 2, .offset = 0 },
        .spans = &.{.{ .start = 0, .cells = &cells }},
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(snapshot));
    const pane = client.model.workspace.findPane(TestHarness.bootstrap_pane).?;

    try std.testing.expectEqual(
        @as(u64, 5),
        pane.applied_frame_id,
    );
    try std.testing.expectEqual(@as(u64, 5), pane.pending_frame_id);
    try std.testing.expectEqual(version.frame + 1, client.model.version().frame);
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);
    try std.testing.expect(client.graphics_store.paneVisible(TestHarness.bootstrap_pane));
    if (comptime core.diagnostics.enabled) {
        try std.testing.expectEqual(frames + 1, client.telemetry.metrics.frames);
        try std.testing.expectEqual(@as(u64, 1), client.telemetry.metrics.snapshots);
        try std.testing.expectEqual(@as(u64, 1), client.telemetry.metrics.frame_spans);
        try std.testing.expectEqual(@as(u64, 4), client.telemetry.metrics.frame_cells);
    }

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(@as(u64, 0), pane.pending_frame_id);
    try harness.settle();

    const ack = try harness.nextClientMessage(&buffer);
    try std.testing.expect(ack == .frame_ack);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, ack.frame_ack.pane_id);
    try std.testing.expectEqual(@as(u64, 5), ack.frame_ack.frame_id);
}

test "a frame made stale by detach has no state resources or presentation effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pane = client.model.workspace.findPane(TestHarness.bootstrap_pane).?;
    pane.attached = false;
    const version = client.model.version();
    const pending_updates = client.presenter.pending_updates;
    const graphics_visible = client.graphics_store.paneVisible(TestHarness.bootstrap_pane);
    const frames = client.telemetry.metrics.frames;
    const cells = [_]core.ui.Cell{.{}};
    var payload: [256]u8 = undefined;
    const snapshot = try schema.encodePaneFrame(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .frame_id = 8,
        .base_frame_id = 0,
        .cols = 1,
        .rows = 1,
        .scroll = .{ .total_rows = 1, .offset = 0 },
        .spans = &.{.{ .start = 0, .cells = &cells }},
    });

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(snapshot));

    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(@as(u64, 0), pane.applied_frame_id);
    try std.testing.expectEqual(@as(u64, 0), pane.pending_frame_id);
    try std.testing.expectEqual(graphics_visible, client.graphics_store.paneVisible(pane.id));
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    if (comptime core.diagnostics.enabled) {
        try std.testing.expectEqual(frames, client.telemetry.metrics.frames);
    }

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);
}

test "pane cwd commits before presenter-owned metadata projection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version = client.model.version();
    const pending_updates = client.presenter.pending_updates;

    var payload: [128]u8 = undefined;
    const cwd = try schema.encodePaneCwd(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .cwd = "/work/telar",
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(cwd));

    try std.testing.expectEqualStrings(
        "/work/telar",
        client.model.workspace.findPane(TestHarness.bootstrap_pane).?.cwdSlice(),
    );
    try std.testing.expectEqual(version.pane_metadata + 1, client.model.version().pane_metadata);
    try std.testing.expectEqual(version.pane_foreground, client.model.version().pane_foreground);
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);
    try std.testing.expect(!client.view.dirty);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expect(!client.view.dirty);
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    const presented_version = client.model.version();
    const presented_updates = client.presenter.pending_updates;
    const same_name = try schema.encodePaneCwd(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .cwd = "/other/telar",
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(same_name));

    try std.testing.expectEqualStrings(
        "/other/telar",
        client.model.workspace.findPane(TestHarness.bootstrap_pane).?.cwdSlice(),
    );
    try std.testing.expectEqualDeep(presented_version, client.model.version());
    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(presented_updates, client.presenter.pending_updates);

    const stale = try schema.encodePaneCwd(&payload, .{
        .pane_id = @enumFromInt(99),
        .cwd = "/missing",
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(stale));
    try std.testing.expectEqualDeep(presented_version, client.model.version());
}

test "pane foreground reaches presentation only after version observation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try harness.addInactiveTab(@enumFromInt(2), @enumFromInt(20));
    const version = client.model.version();
    const pending_updates = client.presenter.pending_updates;

    var payload: [128]u8 = undefined;
    const foreground = try schema.encodePaneForeground(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .name = "Claude Code",
    });
    _ = try server_messages.handleServerMessage(
        client,
        try schema.decodeServer(foreground),
    );

    try std.testing.expectEqualStrings(
        "Claude Code",
        client.model.workspace.findPane(TestHarness.bootstrap_pane).?.foregroundName(),
    );
    try std.testing.expectEqual(version.pane_metadata + 1, client.model.version().pane_metadata);
    try std.testing.expectEqual(version.pane_foreground + 1, client.model.version().pane_foreground);
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);
    try std.testing.expect(!client.view.dirty);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expect(!client.view.dirty);
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    const presented_version = client.model.version();
    const presented_updates = client.presenter.pending_updates;
    _ = try server_messages.handleServerMessage(
        client,
        try schema.decodeServer(foreground),
    );
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(presented_version, client.model.version());
    try std.testing.expectEqual(presented_updates, client.presenter.pending_updates);
}

test "close pane request waits for the authoritative exit before committing" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const closing_pane: schema.PaneId = @enumFromInt(11);
    const split = try client.model.commitPaneSplit(.{
        .split = .{
            .target_pane = TestHarness.bootstrap_pane,
            .location = TestHarness.bootstrap_location,
            .axis = .horizontal,
            .area = client.view.workbench(),
        },
        .new_pane = closing_pane,
    });
    try std.testing.expect(split.change == .changed);
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    _ = client.model.syncReportedPaneFocus().?;
    try std.testing.expectEqual(closing_pane, client.model.beginPanePaste().?.pane_id);
    try client.graphics_store.applyImage(.{
        .pane_id = closing_pane,
        .revision = 1,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        },
    });
    const version_before_request = client.model.version();
    const pending_updates_before_request = client.presenter.pending_updates;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .close_pane);

    try std.testing.expect(client.model.workspace.findPane(closing_pane) != null);
    try std.testing.expectEqualDeep(version_before_request, client.model.version());
    try std.testing.expectEqual(pending_updates_before_request, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 1), client.request_lifecycle.tracker.count);

    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const requested = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(requested == .close_pane);
    try std.testing.expectEqual(closing_pane, requested.close_pane.pane_id);
    try std.testing.expect(requested.close_pane.request_id != .none);
    try std.testing.expect(!client.model.enterCopyMode());

    var payload: [128]u8 = undefined;
    const exited = try schema.encodePaneExited(&payload, .{
        .pane_id = closing_pane,
        .kind = .exited,
        .value = 0,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(exited));

    try std.testing.expect(client.model.workspace.findPane(closing_pane) == null);
    try std.testing.expectEqual(version_before_request.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_request, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(!client.model.panePasteActive());
    try std.testing.expectEqual(@as(?schema.PaneId, TestHarness.bootstrap_pane), reportedPaneId(client));
    try std.testing.expect(!client.graphics_store.hasPaneGraphics(closing_pane));
    try std.testing.expect(!client.notification_scheduler.pending);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_request + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
    const committed_version = client.model.version();
    const pending_updates_after_commit = client.presenter.pending_updates;

    const repeated = try pane_closures.applyExit(client, (try schema.decodeServer(exited)).pane_exited);
    try std.testing.expect(repeated == .stale);
    try std.testing.expectEqual(closing_pane, repeated.stale.pane_id);
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(committed_version, client.model.version());
    try std.testing.expectEqual(pending_updates_after_commit, client.presenter.pending_updates);
}

test "an unrequested pane exit removes the pane silently" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    try std.testing.expect(client.model.enterCopyMode());
    try client.graphics_store.applyImage(.{
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
    const version_before_exit = client.model.version();
    const pending_updates_before_exit = client.presenter.pending_updates;

    var payload: [128]u8 = undefined;
    const exited = try schema.encodePaneExited(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .kind = .exited,
        .value = 0,
    });
    const transition = try pane_closures.applyExit(client, (try schema.decodeServer(exited)).pane_exited);
    try std.testing.expect(transition == .retired);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, transition.retired.pane_id);
    try std.testing.expect(transition.retired.active);
    try std.testing.expect(transition.retired.tab_empty);
    try harness.settle();

    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane) == null);
    try std.testing.expectEqual(version_before_exit.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_exit, client.presenter.pending_updates);
    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expectEqual(@as(?schema.PaneId, null), reportedPaneId(client));
    try std.testing.expect(!client.graphics_store.hasPaneGraphics(TestHarness.bootstrap_pane));
    try std.testing.expect(!client.notification_scheduler.pending);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_exit + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
}

test "an inactive pane exit retires only inactive state" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const inactive_pane: schema.PaneId = @enumFromInt(20);
    const inactive = try harness.addInactiveTab(@enumFromInt(2), inactive_pane);
    try client.graphics_store.applyImage(.{
        .pane_id = inactive_pane,
        .revision = 1,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        },
    });
    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .close_pane = .{
        .pane_id = inactive_pane,
        .location = inactive,
    } });
    try client.request_lifecycle.tracker.add(@enumFromInt(5), .{ .attach_pane = .{
        .pane_id = inactive_pane,
        .location = inactive,
    } });
    const version_before_exit = client.model.version();
    const pending_updates_before_exit = client.presenter.pending_updates;

    var payload: [128]u8 = undefined;
    const exited = try schema.encodePaneExited(&payload, .{
        .pane_id = inactive_pane,
        .kind = .signaled,
        .value = 15,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(exited));

    try std.testing.expect(client.model.workspace.findPane(inactive_pane) == null);
    try std.testing.expectEqualDeep(version_before_exit, client.model.version());
    try std.testing.expectEqual(pending_updates_before_exit, client.presenter.pending_updates);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqual(@as(?schema.PaneId, TestHarness.bootstrap_pane), reportedPaneId(client));
    try std.testing.expect(!client.graphics_store.hasPaneGraphics(inactive_pane));
    try std.testing.expect(client.request_lifecycle.tracker.take(@enumFromInt(4)) == null);
    try std.testing.expect(client.request_lifecycle.tracker.take(@enumFromInt(5)).? == .ignored);
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_exit + 1, client.presenter.pending_updates);
}
