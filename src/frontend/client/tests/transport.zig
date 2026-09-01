//! Client integration tests for transport.

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
const client_layout_resource = @import("../resources/client_layouts.zig");
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

test "host input arriving while no tab exists is dropped, not a crash" {
    // The workspace-handoff window: `tabs.deinit()` has run and the new
    // pane has not been confirmed. A keystroke here used to null-unwrap.
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    var chunk: InputChunk = .{};
    chunk.bytes[0] = 'x';
    chunk.len = 1;
    try std.testing.expect(!try host_inputs.handleRead(harness.client, chunk));
    try std.testing.expectEqual(@as(usize, 0), harness.client.runtime_transport.outbox.len);
}

test "host input reads pause at outbox capacity and resume with one token" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    try runtime_transport.enqueue(client, .{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    while (client.runtime_transport.outbox.hasCapacity()) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }

    try host_inputs.scheduleRead(client);
    try std.testing.expect(!client.host_input.read_pending);

    switch (try client.select.await()) {
        .sent => |result| try runtime_transport.handleSent(client, result),
        else => return error.UnexpectedEvent,
    }
    try std.testing.expectEqual(client_outbox.capacity - 1, @as(usize, client.runtime_transport.outbox.len));
    try std.testing.expect(client.runtime_transport.outbox.inFlight());
    try std.testing.expect(client.host_input.read_pending);

    try host_inputs.scheduleRead(client);
    try std.testing.expect(client.host_input.read_pending);
}

test "runtime reads own one token and do not rearm after shutdown" {
    const io = std.testing.io;
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;

    try runtime_transport.scheduleRead(client);
    try runtime_transport.scheduleRead(client);
    try std.testing.expect(client.runtime_transport.receive_pending);

    var payload: [64]u8 = undefined;
    const metrics = try schema.encodeSystemMetrics(&payload, .{
        .revision = 1,
        .cpu_percent = 50,
        .memory_used_decigib = 10,
        .has_battery = false,
        .battery_percent = 0,
    });
    try harness.peer.send(io, metrics);
    switch (try client.select.await()) {
        .server => |result| try std.testing.expectEqual(
            @as(?u8, null),
            try runtime_transport.handleRead(client, result),
        ),
        else => return error.UnexpectedEvent,
    }
    try std.testing.expect(client.runtime_transport.receive_pending);
    try std.testing.expectEqual(@as(u64, 1), client.model.systemMetrics().?.runtime_revision);

    try harness.peer.send(io, try schema.encodeRuntimeStopping(&payload));
    switch (try client.select.await()) {
        .server => |result| try std.testing.expectEqual(
            @as(?u8, 0),
            try runtime_transport.handleRead(client, result),
        ),
        else => return error.UnexpectedEvent,
    }
    try std.testing.expect(!client.runtime_transport.receive_pending);

    client.runtime_transport.receive_pending = true;
    try std.testing.expectError(
        error.RuntimeReadFailed,
        runtime_transport.handleRead(client, error.RuntimeReadFailed),
    );
    try std.testing.expect(!client.runtime_transport.receive_pending);
}

test "graphics credits remain owned until the outbox accepts them" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const pane_id: schema.PaneId = @enumFromInt(7);
    try client.graphics_store.applyImage(.{
        .pane_id = pane_id,
        .revision = 1,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgba,
            .width = 1,
            .height = 1,
            .byte_len = 4,
        },
    });
    try client.graphics_store.applySnapshot(.{
        .pane_id = pane_id,
        .revision = 2,
        .phase = .begin,
    });
    while (client.runtime_transport.outbox.hasCapacity()) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = pane_id } });
    }

    try runtime_transport.flushGraphicsCredits(client);
    try std.testing.expectEqual(@as(usize, 4), client.graphics_store.peekCredit().?.bytes);
    try std.testing.expect(client.runtime_transport.outbox.inFlight());

    switch (try client.select.await()) {
        .sent => |result| try runtime_transport.handleSent(client, result),
        else => return error.UnexpectedEvent,
    }
    try std.testing.expect(client.graphics_store.peekCredit() == null);
    try std.testing.expectEqual(client_outbox.capacity, @as(usize, client.runtime_transport.outbox.len));
    try std.testing.expect(client.runtime_transport.outbox.inFlight());
}

test "runtime write errors release the outbound token" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    try client.runtime_transport.outbox.push(.{
        .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane },
    });
    _ = (try client.runtime_transport.outbox.beginSend(client.runtime_transport.send_buffer)).?;

    try std.testing.expectError(
        error.RuntimeWriteFailed,
        runtime_transport.handleSent(client, error.RuntimeWriteFailed),
    );
    try std.testing.expect(!client.runtime_transport.outbox.inFlight());
    try std.testing.expectEqual(@as(u8, 1), client.runtime_transport.outbox.len);
}

test "request delivery rolls correlation back when transport is full" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    while (client.runtime_transport.outbox.hasCapacity()) {
        try client.runtime_transport.outbox.push(.{
            .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane },
        });
    }
    const request_id = try request_lifecycle.nextId(client);

    try std.testing.expectError(error.ClientOutboxFull, request_lifecycle.deliver(client, .{
        .registration = .{
            .request_id = request_id,
            .continuation = .{ .tab_snapshot = TestHarness.bootstrap_location },
        },
        .message = .{ .request_tab_snapshot = .{
            .request_id = request_id,
            .location = TestHarness.bootstrap_location,
        } },
    }));
    try std.testing.expect(request_lifecycle.consume(client, request_id) == null);
    try std.testing.expect(client.request_lifecycle.tracker.isEmpty());
}

test "client startup validates geometry before request registration" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    try client.view.resize(1, 1);

    try std.testing.expectError(error.TerminalTooSmall, client_startup.start(client, .{
        .resize_watcher = undefined,
    }));

    try std.testing.expect(client.request_lifecycle.tracker.isEmpty());
    try std.testing.expect(!client.runtime_transport.receive_pending);
}

test "client startup waits for runtime layout before its initial open" {
    var tty: platform.Tty = undefined;
    var watcher = try platform.ResizeWatcher.init(&tty);
    defer watcher.deinit();
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.options.arguments = &.{"/bin/sh"};
    const expected_size = workspace_capability.multiplexer.rectSize(client.view.workbench()).?;

    try client_startup.start(client, .{
        .resize_watcher = &watcher,
    });

    try std.testing.expect(client.request_lifecycle.tracker.isEmpty());
    try std.testing.expect(client.runtime_transport.receive_pending);
    var buffer: [256]u8 = undefined;
    const configure = try harness.nextClientMessage(&buffer);
    try std.testing.expect(configure == .configure_graphics);
    try std.testing.expectEqual(
        kitty.clientSupportsSharedMemory(),
        configure.configure_graphics.shared,
    );
    const runtime_state = try harness.nextClientMessage(&buffer);
    try std.testing.expect(runtime_state == .request_runtime_state);
    try std.testing.expectEqual(client.client_identity, runtime_state.request_runtime_state.client_identity);

    const empty_layout = try schema.encodeClientLayoutSnapshot(&buffer, .{ .restored = false });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(empty_layout));
    try harness.settle();

    try std.testing.expect(request_lifecycle.has(client, .initial_open));
    const open = try harness.nextClientMessage(&buffer);
    try std.testing.expect(open == .open_pane);
    try std.testing.expectEqual(initial_request_id, open.open_pane.request_id);
    try std.testing.expectEqualDeep(expected_size, open.open_pane.size);
    try std.testing.expectEqualStrings("/", open.open_pane.launch.?.cwd);
    var arguments = open.open_pane.launch.?.arguments();
    try std.testing.expectEqualStrings("/bin/sh", (try arguments.next()).?);
    try std.testing.expect((try arguments.next()) == null);
}

test "restored client layout controls the initial attach geometry" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(7) },
        .tab_id = @enumFromInt(9),
    };
    const pane_id: schema.PaneId = @enumFromInt(44);
    const nodes = [_]schema.ClientLayoutNode{.{ .pane = pane_id }};
    const tabs = [_]schema.ClientTabLayout{.{
        .location = location,
        .focused_pane = pane_id,
        .fullscreen = false,
        .workspace_active = true,
        .nodes = &nodes,
    }};
    const restored: schema.ClientLayoutSnapshot = .{
        .restored = true,
        .sidebar_visible = true,
        .sidebar_width = 50,
        .workspace_list_collapsed = true,
        .active_tab = location,
        .tabs = &tabs,
    };
    var buffer: [schema.max_client_layout_wire_bytes]u8 = undefined;
    const payload = try schema.encodeClientLayoutSnapshot(&buffer, restored);

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(payload));
    try harness.settle();

    try std.testing.expect(client.model.sidebarVisible());
    try std.testing.expectEqual(@as(u16, 50), client.model.sidebarWidth());
    try std.testing.expect(client.model.workspaceListCollapsed());
    try std.testing.expectEqual(@as(u16, 50), client.view.regions.sidebar.w);
    try std.testing.expectEqual(@as(u16, 50), client.view.regions.top.x);
    try std.testing.expectEqual(pane_id, client.saved_layouts.find(location).?.pane_id);
    try std.testing.expectEqual(pane_id, client.navigation_history.find(location.workspace).?.pane_id);

    const open = try harness.nextClientMessage(&buffer);
    try std.testing.expect(open == .open_pane);
    try std.testing.expect(open.open_pane.target == .pane);
    try std.testing.expectEqual(pane_id, open.open_pane.target.pane);
    try std.testing.expect(open.open_pane.launch == null);
    try std.testing.expectEqualDeep(
        workspace_capability.multiplexer.rectSize(client.view.workbench()).?,
        open.open_pane.size,
    );

    const duplicate_payload = try schema.encodeClientLayoutSnapshot(&buffer, restored);
    try std.testing.expectError(
        error.DuplicateClientLayoutSnapshot,
        server_messages.handleServerMessage(client, try schema.decodeServer(duplicate_payload)),
    );
}

test "sidebar preferences survive when retained pane layouts become stale" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.options.arguments = &.{"/bin/sh"};
    var buffer: [schema.max_client_layout_wire_bytes]u8 = undefined;
    const payload = try schema.encodeClientLayoutSnapshot(&buffer, .{
        .restored = true,
        .sidebar_visible = true,
        .sidebar_width = 51,
        .workspace_list_collapsed = true,
    });

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(payload));
    try harness.settle();

    try std.testing.expectEqual(@as(u16, 51), client.model.sidebarWidth());
    try std.testing.expect(client.model.workspaceListCollapsed());
    const open = try harness.nextClientMessage(&buffer);
    try std.testing.expect(open == .open_pane);
    try std.testing.expect(open.open_pane.target == .default);
    try std.testing.expect(open.open_pane.launch != null);
}

test "bootstrap answers the initial open with both snapshot requests" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();

    try std.testing.expectEqual(@as(usize, 1), harness.client.model.workspace.count);
    const pane = harness.client.model.workspace.findPane(TestHarness.bootstrap_pane).?;
    try std.testing.expect(pane.attached);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, reportedPaneId(harness.client));
    try std.testing.expectEqual(@as(u64, 1), harness.client.model.version().workspace);
    try std.testing.expectEqual(@as(u64, 1), harness.client.model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), harness.client.model.version().active_tab);
    try std.testing.expectEqual(@as(u64, 1), harness.client.model.version().panes);
    try std.testing.expectEqualDeep(
        harness.client.model.version(),
        harness.client.presenter.presented_model_version,
    );
}

test "client layout observation sends one canonical workspace update" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.workspace.active().?.snapshot_loaded = true;
    try client.client_layouts.markSnapshotReceived();
    try std.testing.expect(client.model.restoreSidebarLayout(true, 53) != null);
    try std.testing.expect(client.model.setWorkspaceListCollapsed(true) != null);

    try client_layout_resource.observe(client);
    try std.testing.expectEqual(@as(u8, 1), client.runtime_transport.outbox.len);
    try client_layout_resource.observe(client);
    try std.testing.expectEqual(@as(u8, 1), client.runtime_transport.outbox.len);
    try harness.settle();

    var buffer: [schema.max_client_layout_wire_bytes]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .update_client_layout);
    const update = message.update_client_layout;
    try std.testing.expect(update.sidebar_visible);
    try std.testing.expectEqual(@as(u16, 53), update.sidebar_width);
    try std.testing.expect(update.workspace_list_collapsed);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, update.active_tab);
    try std.testing.expectEqual(@as(u16, 1), update.tab_count);
    var tabs = update.tabs();
    const tab = (try tabs.next()).?;
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, tab.location);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, tab.focused_pane);
    try std.testing.expect(tab.workspace_active);
    var nodes = tab.nodes();
    const node = (try nodes.next()).?;
    try std.testing.expectEqual(TestHarness.bootstrap_pane, node.pane);
    try std.testing.expect(try nodes.next() == null);
    try std.testing.expect(try tabs.next() == null);
}
