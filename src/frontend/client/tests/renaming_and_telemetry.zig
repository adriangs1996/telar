//! Client integration tests for renaming and telemetry.

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

test "workspace rename separates prompt submission canonical commit and presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before_prompt = client.model.version();
    const pending_updates_before_prompt = client.presenter.pending_updates;

    try std.testing.expect(name_prompts.beginWorkspaceRename(client));
    try std.testing.expect(client.model.name_prompt.active());
    try std.testing.expectEqualStrings("", client.model.name_prompt.currentConst().?.field.text());
    try expectNonPromptVersionEqual(version_before_prompt, client.model.version());
    try std.testing.expect(client.model.version().prompt > version_before_prompt.prompt);
    try std.testing.expectEqual(pending_updates_before_prompt, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates_before_prompt + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    const version_before_request = client.model.version();
    const pending_updates_before_request = client.presenter.pending_updates;
    var handler: InputHandler = .{ .client = client };
    try handler.forward("mainx\r");

    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(!client.model.name_prompt.active());
    try std.testing.expectEqualStrings("", client.model.workspace.workspaceName());
    try expectNonPromptVersionEqual(version_before_request, client.model.version());
    try std.testing.expect(client.model.version().prompt > version_before_request.prompt);
    try std.testing.expectEqual(pending_updates_before_request, client.presenter.pending_updates);
    const version_after_request = client.model.version();
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .rename_workspace);
    try std.testing.expectEqualStrings("mainx", message.rename_workspace.name);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location.workspace, message.rename_workspace.workspace);

    var payload: [512]u8 = undefined;
    const renamed = try schema.encodeWorkspaceSnapshot(&payload, .{
        .request_id = message.rename_workspace.request_id,
        .workspace = message.rename_workspace.workspace,
        .name = message.rename_workspace.name,
        .tabs = &.{
            .{ .tab_id = TestHarness.bootstrap_location.tab_id, .position = 0, .pane_count = 1, .label = "main" },
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(renamed));

    try std.testing.expectEqualStrings("mainx", client.model.workspace.workspaceName());
    try std.testing.expectEqual(version_before_request.workspace + 1, client.model.version().workspace);
    try std.testing.expectEqual(version_before_request.tabs, client.model.version().tabs);
    try std.testing.expectEqual(version_before_request.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(version_after_request.prompt, client.model.version().prompt);
    try std.testing.expectEqual(pending_updates_before_request, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_request + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    const version_before_noop = client.model.version();
    const pending_updates_before_noop = client.presenter.pending_updates;
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{
        .rename_workspace = TestHarness.bootstrap_location.workspace,
    });
    const unchanged = try schema.encodeWorkspaceSnapshot(&payload, .{
        .request_id = @enumFromInt(90),
        .workspace = TestHarness.bootstrap_location.workspace,
        .name = "mainx",
        .tabs = &.{
            .{ .tab_id = TestHarness.bootstrap_location.tab_id, .position = 0, .pane_count = 1, .label = "main" },
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(unchanged));
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(version_before_noop, client.model.version());
    try std.testing.expectEqual(pending_updates_before_noop, client.presenter.pending_updates);
}

test "pending workspace operation keeps the rename prompt without sending" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{
        .rename_workspace = TestHarness.bootstrap_location.workspace,
    });
    const next_request_id = client.request_lifecycle.next_request_id;
    const version_before_request = client.model.version();

    try std.testing.expect(name_prompts.beginWorkspaceRename(client));
    var handler: InputHandler = .{ .client = client };
    try handler.forward("x\r");

    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(client.model.name_prompt.active());
    try std.testing.expectEqual(next_request_id, client.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try expectNonPromptVersionEqual(version_before_request, client.model.version());
    try std.testing.expect(client.model.version().prompt > version_before_request.prompt);

    try handler.forward("\x1b");
    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(!client.model.name_prompt.active());
}

test "an unexpected tab rename is rejected without effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    const renamed: schema.TabRenamed = .{
        .request_id = @enumFromInt(99),
        .location = TestHarness.bootstrap_location,
        .label = "canonical",
    };

    try std.testing.expectError(error.UnexpectedTabRenamed, tab_renames.apply(client, renamed));

    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expectEqualStrings("main", client.model.workspace.activeConst().?.labelSlice());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "tab rename consumes an incompatible continuation before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const request_id: schema.RequestId = @enumFromInt(90);
    const version_before = client.model.version();
    try client.request_lifecycle.tracker.add(request_id, .notification);
    const renamed: schema.TabRenamed = .{
        .request_id = request_id,
        .location = TestHarness.bootstrap_location,
        .label = "canonical",
    };

    try std.testing.expectError(error.UnexpectedTabRenamed, tab_renames.apply(client, renamed));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabRenamed, tab_renames.apply(client, renamed));
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqualStrings("main", client.model.workspace.activeConst().?.labelSlice());
}

test "tab rename consumes a mismatched location before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const request_id: schema.RequestId = @enumFromInt(90);
    const version_before = client.model.version();
    try client.request_lifecycle.tracker.add(request_id, .{ .rename_tab = TestHarness.bootstrap_location });
    const renamed: schema.TabRenamed = .{
        .request_id = request_id,
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(9) },
            .tab_id = TestHarness.bootstrap_location.tab_id,
        },
        .label = "canonical",
    };

    try std.testing.expectError(error.UnexpectedTabRenamed, tab_renames.apply(client, renamed));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqualStrings("main", client.model.workspace.activeConst().?.labelSlice());
}

test "tab rename consumes a canonical response rejected by the model" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const request_id: schema.RequestId = @enumFromInt(90);
    const missing: schema.TabLocation = .{
        .workspace = TestHarness.bootstrap_location.workspace,
        .tab_id = @enumFromInt(9),
    };
    const version_before = client.model.version();
    try client.request_lifecycle.tracker.add(request_id, .{ .rename_tab = missing });
    const renamed: schema.TabRenamed = .{
        .request_id = request_id,
        .location = missing,
        .label = "canonical",
    };

    try std.testing.expectError(error.UnexpectedTabRenamed, tab_renames.apply(client, renamed));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabRenamed, tab_renames.apply(client, renamed));
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqualStrings("main", client.model.workspace.activeConst().?.labelSlice());
}

test "tab rename separates prompt submission canonical commit and presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const version_before_request = client.model.version();
    const pending_updates_before_request = client.presenter.pending_updates;

    try std.testing.expect(name_prompts.beginTabRename(client, TestHarness.bootstrap_location.tab_id));
    var handler: InputHandler = .{ .client = client };
    try std.testing.expect(handler.capturesKeys());

    try handler.forward("x");
    try handler.forward("\r");
    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(!client.model.name_prompt.active());
    try std.testing.expectEqualStrings("main", client.model.workspace.activeConst().?.labelSlice());
    try expectNonPromptVersionEqual(version_before_request, client.model.version());
    try std.testing.expect(client.model.version().prompt > version_before_request.prompt);
    try std.testing.expectEqual(pending_updates_before_request, client.presenter.pending_updates);
    const version_after_request = client.model.version();
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .rename_tab);
    try std.testing.expectEqualStrings("mainx", message.rename_tab.label);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, message.rename_tab.location);
    const continuation = client.request_lifecycle.tracker.take(message.rename_tab.request_id).?;
    try std.testing.expect(continuation == .rename_tab);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, continuation.rename_tab);
    try client.request_lifecycle.tracker.add(message.rename_tab.request_id, continuation);

    var payload: [256]u8 = undefined;
    const renamed = try schema.encodeTabRenamed(&payload, .{
        .request_id = message.rename_tab.request_id,
        .location = message.rename_tab.location,
        .label = "canonical",
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(renamed));
    @memset(&payload, 'x');

    try std.testing.expectEqualStrings("canonical", client.model.workspace.activeConst().?.labelSlice());
    try std.testing.expectEqual(version_before_request.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_request.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(version_after_request.prompt, client.model.version().prompt);
    try std.testing.expectEqual(pending_updates_before_request, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_request + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    const version_before_noop = client.model.version();
    const pending_updates_before_noop = client.presenter.pending_updates;
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{ .rename_tab = TestHarness.bootstrap_location });
    const unchanged = try schema.encodeTabRenamed(&payload, .{
        .request_id = @enumFromInt(90),
        .location = TestHarness.bootstrap_location,
        .label = "canonical",
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(unchanged));
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(version_before_noop, client.model.version());
    try std.testing.expectEqual(pending_updates_before_noop, client.presenter.pending_updates);
}

test "tab rename response must match the requested identity" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};

    try std.testing.expect(name_prompts.beginTabRename(client, TestHarness.bootstrap_location.tab_id));
    var handler: InputHandler = .{ .client = client };
    try handler.forward("x\r");
    const version_before_response = client.model.version();
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&message_buffer);
    var response_buffer: [256]u8 = undefined;
    const response = try schema.encodeTabRenamed(&response_buffer, .{
        .request_id = message.rename_tab.request_id,
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(9) },
            .tab_id = message.rename_tab.location.tab_id,
        },
        .label = "canonical",
    });

    try std.testing.expectError(
        error.UnexpectedTabRenamed,
        server_messages.handleServerMessage(client, try schema.decodeServer(response)),
    );

    try std.testing.expectEqualStrings("main", client.model.workspace.activeConst().?.labelSlice());
    try std.testing.expectEqualDeep(version_before_response, client.model.version());
    try std.testing.expect(!client.request_lifecycle.tracker.has(.tab_operation));
}

test "a failed tab rename preserves the label and notifies" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};

    try std.testing.expect(name_prompts.beginTabRename(client, TestHarness.bootstrap_location.tab_id));
    var handler: InputHandler = .{ .client = client };
    try handler.forward("x\r");
    const version_before_failure = client.model.version();
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&message_buffer);
    var response_buffer: [256]u8 = undefined;
    const response = try schema.encodeRequestFailed(&response_buffer, .{
        .request_id = message.rename_tab.request_id,
        .code = .tab_not_found,
        .message = "tab not found",
    });

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(response));

    try std.testing.expectEqualStrings("main", client.model.workspace.activeConst().?.labelSlice());
    try expectOnlyNotificationVersionChanged(version_before_failure, client.model.version());
    try std.testing.expect(!client.request_lifecycle.tracker.has(.tab_operation));
    try std.testing.expect(client.notification_scheduler.pending);
}

test "pending tab operation keeps the rename prompt without sending" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{ .move_tab = TestHarness.bootstrap_location });
    const next_request_id = client.request_lifecycle.next_request_id;
    const version_before_request = client.model.version();

    try std.testing.expect(name_prompts.beginTabRename(client, TestHarness.bootstrap_location.tab_id));
    var handler: InputHandler = .{ .client = client };
    try handler.forward("x\r");

    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(client.model.name_prompt.active());
    try std.testing.expectEqual(next_request_id, client.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try expectNonPromptVersionEqual(version_before_request, client.model.version());
    try std.testing.expect(client.model.version().prompt > version_before_request.prompt);

    try handler.forward("\x1b");
    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(!client.model.name_prompt.active());
}

test "a full outbox keeps the tab rename prompt and rolls back correlation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const version_before_request = client.model.version();
    while (client.runtime_transport.outbox.hasCapacity()) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }

    try std.testing.expect(name_prompts.beginTabRename(client, TestHarness.bootstrap_location.tab_id));
    var handler: InputHandler = .{ .client = client };

    try std.testing.expectError(error.ClientOutboxFull, handler.forward("x\r"));

    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(client.model.name_prompt.active());
    try std.testing.expect(!client.request_lifecycle.tracker.has(.tab_operation));
    try std.testing.expectEqual(client_outbox.capacity, @as(usize, client.runtime_transport.outbox.len));
    try std.testing.expectEqualStrings("main", client.model.workspace.activeConst().?.labelSlice());
    try expectNonPromptVersionEqual(version_before_request, client.model.version());
    try std.testing.expect(client.model.version().prompt > version_before_request.prompt);
}

test "escaping the prompt editor closes model state without changing mode" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};

    try std.testing.expect(name_prompts.beginWorkspaceCreate(client));
    try std.testing.expect(client.model.name_prompt.active());
    try std.testing.expect(!client.model.copyModeActive());
    var handler: InputHandler = .{ .client = client };
    try handler.forward("\x1b");
    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(!client.model.name_prompt.active());
}

test "client telemetry writes one snapshot without mutating semantic state" {
    if (!core.diagnostics.enabled) {
        return;
    }

    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const model_version = client.model.version();
    const presented_version = client.presenter.presented_model_version;
    const file = try temp.dir.createFile(io, "client.log", .{});
    client.telemetry.sink.deinit(io);
    client.telemetry.sink = .{ .file = file };
    client.telemetry.enabled = true;

    client_telemetry.handleTick(client, {}, .{ .observation_allocs = 7 });

    try std.testing.expect(client.telemetry.write_pending);
    const line_end = (std.mem.indexOfScalar(u8, &client.telemetry.buffer, '\n') orelse
        return error.TelemetryLineMissing) + 1;
    const line = client.telemetry.buffer[0..line_end];
    try std.testing.expect(std.mem.indexOf(u8, line, "\"role\":\"client\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"active_tab\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"observation_allocs\":7") != null);

    switch (try client.select.await()) {
        .telemetry_written => |result| client_telemetry.handleWritten(client, result),
        else => return error.UnexpectedEvent,
    }
    try std.testing.expect(!client.telemetry.write_pending);
    try std.testing.expect(client.telemetry.enabled);
    try std.testing.expect(client.telemetry.sink.available());
    try std.testing.expectEqualDeep(model_version, client.model.version());
    try std.testing.expectEqualDeep(presented_version, client.presenter.presented_model_version);

    client_telemetry.handleTick(client, error.TickFailed, .{});
    try std.testing.expect(!client.telemetry.enabled);
    try std.testing.expect(!client.telemetry.sink.available());
}
