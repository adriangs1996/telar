//! Client integration tests for configuration.

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

test "config reload outcomes that carry no new generation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;

    try std.testing.expectEqual(
        config_reloads.Outcome.unchanged,
        try config_reloads.handle(client, .{ .unchanged = 42 }),
    );
    try std.testing.expectEqual(@as(i128, 42), client.reload.mtime_ns);

    var diagnostic: lua_config.Diagnostic = .{};
    diagnostic.set("bad config: {s}", .{"boom"});
    try std.testing.expectEqual(
        config_reloads.Outcome.rejected,
        try config_reloads.handle(client, .{ .failed = .{
            .diagnostic = diagnostic,
            .mtime_ns = 7,
        } }),
    );
    try std.testing.expectEqual(@as(i128, 7), client.reload.mtime_ns);
    try std.testing.expect(client.notification_scheduler.pending);
    try std.testing.expect(client.model.diagnostic() != null);
    try harness.settle();
}

test "resolved configuration adoption crosses delivery before watcher rearm" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const candidate = try testingConfigAdoption(1, false);
    const generation = candidate.generation;

    const outcome = try config_reloads.handle(client, .{ .loaded = .{
        .generation = candidate.generation,
        .registry = candidate.registry,
        .trust_store = candidate.trust_store,
        .mtime_ns = 19,
    } });

    try std.testing.expectEqual(@as(u64, 1), outcome.adopted.generation);
    try std.testing.expect(client.lua_generation == generation);
    try std.testing.expectEqual(@as(i128, 19), client.reload.mtime_ns);
    try std.testing.expectEqual(client_model.Version{
        .configuration = 1,
        .notifications = 1,
    }, client.model.version());
    try std.testing.expect(client.notification_scheduler.pending);
    try harness.settle();
}

test "configuration adoption swaps ownership after commit and presents by version" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    var previous_diagnostic: lua_config.Diagnostic = .{};
    previous_diagnostic.set("previous configuration failed", .{});
    _ = try client.model.replaceDiagnostic(previous_diagnostic);
    const initial = try testingConfigAdoption(1, false);
    const initial_generation = initial.generation;

    const first = try config_reloads.apply(client, initial);

    try std.testing.expectEqual(@as(u64, 1), first.generation);
    try std.testing.expect(client.lua_generation == initial_generation);
    try std.testing.expectEqual(@as(u64, 1), client.model.configurationGeneration());
    try std.testing.expect(client.model.diagnostic() == null);

    try std.testing.expectEqualDeep(
        sound_capability.RequestOutcome{ .start = .ready },
        client.sound_playback.request(.ready),
    );
    try std.testing.expect(client.sound_playback.request(.ready) == .queued);
    const pending_updates = client.presenter.pending_updates;
    const changed = try testingConfigAdoption(2, true);
    const changed_generation = changed.generation;
    const second = try config_reloads.apply(client, changed);

    try std.testing.expectEqual(@as(u64, 2), second.generation);
    try std.testing.expectEqual(@as(u64, 2), second.configuration_revision);
    try std.testing.expect(!second.sidebar.?.visible);
    try std.testing.expect(second.pane_gaps_changed);
    try std.testing.expect(client.lua_generation == changed_generation);
    try std.testing.expectEqual(@as(u64, 2), client.model.configurationGeneration());
    try std.testing.expect(!client.model.sidebarVisible());
    try std.testing.expect(!client.model.paneGaps());
    try std.testing.expect(!client.view.sidebar_requested);
    try std.testing.expectEqualDeep(try keybind.parseKey("ctrl+s"), client.host_input.router.prefix.?);
    try std.testing.expectEqual(
        @as(u64, 40 * std.time.ns_per_ms),
        client.host_input.router.escape_timeout_ns,
    );
    try std.testing.expectEqual(
        @as(u64, 750 * std.time.ns_per_ms),
        client.host_input.router.sequence_timeout_ns,
    );
    try std.testing.expectEqual(sound_capability.Snapshot{
        .configuration = .{ .enabled = false },
        .active = true,
        .queued = null,
    }, client.sound_playback.snapshot());
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();

    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
    try std.testing.expectEqual(client_model.Version{
        .configuration = 2,
        .diagnostic = 2,
        .panes = 1,
        .chrome = 1,
    }, client.model.version());

    const stale = try testingConfigAdoption(2, false);
    try std.testing.expectError(error.StaleConfiguration, config_reloads.apply(client, stale));
    try std.testing.expect(client.lua_generation == changed_generation);
    try std.testing.expectEqual(@as(u64, 2), client.model.configurationGeneration());
}

test "configuration adoption keeps new ownership after geometry failure" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    while (client.runtime_transport.outbox.hasCapacity()) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const adoption = try testingConfigAdoption(1, true);
    const generation = adoption.generation;

    try std.testing.expectError(error.ClientOutboxFull, config_reloads.apply(client, adoption));

    try std.testing.expect(client.lua_generation == generation);
    try std.testing.expectEqual(@as(u64, 1), client.model.configurationGeneration());
    try std.testing.expectEqual(@as(u64, 1), client.model.version().configuration);
    try std.testing.expect(!client.model.sidebarVisible());
    try std.testing.expect(!client.model.paneGaps());
    try std.testing.expect(!client.view.sidebar_requested);
    try std.testing.expectEqual(@as(usize, client_outbox.capacity), client.runtime_transport.outbox.len);
}

test "a configuration version alone schedules presenter observation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const pending_updates = client.presenter.pending_updates;

    _ = try client.model.applyConfiguration(.{
        .generation = 1,
        .sidebar_visible = true,
        .pane_gaps = true,
    });

    try std.testing.expectEqual(client_model.Version{ .configuration = 1 }, client.model.version());
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();

    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
}

test "plugin completion applies one authorized batch through model observation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const installed = try installTestingPlugin(client);
    const execution = (try client.model.beginPluginExecution()).?;
    var batch: lua_config.EffectBatch = .{};
    batch.items[0] = .toggle_workspace_list;
    batch.len = 1;
    const version_before = client.model.version();
    const pending_before = client.presenter.pending_updates;

    const exit = try plugin_actions.complete(client, .{
        .execution_id = execution.id,
        .result = plugin_broker.WorkerResult{
            .package_index = 0,
            .plugin_id = installed.action.plugin,
            .digest = installed.digest,
            .batch = batch,
        },
    });

    try std.testing.expect(!exit);
    try std.testing.expect(client.model.pluginExecution() == null);
    try std.testing.expect(client.model.workspaceListCollapsed());
    try std.testing.expectEqual(version_before.chrome + 1, client.model.version().chrome);
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);
    try std.testing.expect(!client.view.workspace_list_collapsed);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_before + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expect(client.view.workspace_list_collapsed);
}

test "plugin completion from an old configuration is consumed without effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const installed = try installTestingPlugin(client);
    const execution = (try client.model.beginPluginExecution()).?;
    var batch: lua_config.EffectBatch = .{};
    batch.items[0] = .toggle_workspace_list;
    batch.len = 1;

    _ = try client.model.applyConfiguration(.{
        .generation = 1,
        .sidebar_visible = true,
        .pane_gaps = true,
    });
    const version_after_reload = client.model.version();
    const pending_before = client.presenter.pending_updates;

    const exit = try plugin_actions.complete(client, .{
        .execution_id = execution.id,
        .result = plugin_broker.WorkerResult{
            .package_index = 0,
            .plugin_id = installed.action.plugin,
            .digest = installed.digest,
            .batch = batch,
        },
    });

    try std.testing.expect(!exit);
    try std.testing.expect(client.model.pluginExecution() == null);
    try std.testing.expect(!client.model.workspaceListCollapsed());
    try std.testing.expectEqualDeep(version_after_reload, client.model.version());
    try std.testing.expect(client.model.diagnostic() == null);
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);
}

test "plugin authorization denial consumes the run before publishing failure" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const installed = try installTestingPlugin(client);
    const execution = (try client.model.beginPluginExecution()).?;
    var batch: lua_config.EffectBatch = .{};
    batch.items[0] = .close_pane;
    batch.len = 1;
    const version_before = client.model.version();
    const pending_before = client.presenter.pending_updates;

    const exit = try plugin_actions.complete(client, .{
        .execution_id = execution.id,
        .result = plugin_broker.WorkerResult{
            .package_index = 0,
            .plugin_id = installed.action.plugin,
            .digest = installed.digest,
            .batch = batch,
        },
    });

    try std.testing.expect(!exit);
    try std.testing.expect(client.model.pluginExecution() == null);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane) != null);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expect(client.model.version().notifications > version_before.notifications);
    try std.testing.expect(std.mem.indexOf(
        u8,
        client.model.diagnostic().?,
        "CapabilityNotGranted",
    ) != null);
    try std.testing.expect(client.notification_scheduler.pending);
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_before + 1, client.presenter.pending_updates);
}

test "plugin worker failure and unmatched completion preserve lifecycle identity" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const execution = (try client.model.beginPluginExecution()).?;

    try std.testing.expect(!try plugin_actions.complete(client, .{
        .execution_id = @enumFromInt(@intFromEnum(execution.id) + 1),
        .result = error.TestPluginWorkerFailure,
    }));
    try std.testing.expectEqualDeep(execution, client.model.pluginExecution().?);
    try std.testing.expect(client.model.diagnostic() == null);

    try std.testing.expect(!try plugin_actions.complete(client, .{
        .execution_id = execution.id,
        .result = error.TestPluginWorkerFailure,
    }));
    try std.testing.expect(client.model.pluginExecution() == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        client.model.diagnostic().?,
        "TestPluginWorkerFailure",
    ) != null);
    try std.testing.expect(client.notification_scheduler.pending);
}

test "busy plugin start skips resolution and a rejected action leaves no run" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const installed = try installTestingPlugin(client);
    const execution = (try client.model.beginPluginExecution()).?;

    const busy = try plugin_actions.start(client, installed.action, testing_plugin_context);

    try std.testing.expect(busy == .busy);
    try std.testing.expectEqualDeep(execution, client.model.pluginExecution().?);
    _ = client.model.finishPluginExecution(execution.id);

    const rejected = try plugin_actions.start(client, .{
        .plugin = installed.action.plugin,
        .action = core.plugin.stableId("missing"),
    }, testing_plugin_context);

    try std.testing.expectEqual(error.UnknownPluginAction, rejected.rejected);
    try std.testing.expect(client.model.pluginExecution() == null);
    try std.testing.expect(client.notification_scheduler.pending);
    try std.testing.expect(std.mem.indexOf(
        u8,
        client.model.diagnostic().?,
        "UnknownPluginAction",
    ) != null);
}

test "name prompt suppresses a configured action before source dispatch" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    try std.testing.expect(name_prompts.beginActiveTabRename(client));
    const version = client.model.version();
    const outbox_len = client.runtime_transport.outbox.len;
    var handler: InputHandler = .{ .client = client };

    const control = try handler.action(.toggle_sidebar);

    try std.testing.expect(control == .continue_routing);
    try std.testing.expect(client.model.name_prompt.active());
    try std.testing.expect(client.model.sidebarVisible());
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(outbox_len, client.runtime_transport.outbox.len);
}

test "Lua callback applies a validated batch through model observation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const configured = try installTestingLuaBinding(client,
        \\local telar = require("telar")
        \\return {
        \\  api_version = 2,
        \\  client = { keybindings = {
        \\    telar.bind({ "x" }, function(ctx)
        \\      if ctx.tab_count ~= 1 or ctx.pane_count ~= 1 or ctx.focused_pane_id ~= 10 then
        \\        error("bad callback context")
        \\      end
        \\      return telar.action.toggle_workspace_list()
        \\    end),
        \\  } },
        \\}
    );
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    _ = try client.model.setDiagnostic("old diagnostic", .{});
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    const version_before = client.model.version();
    const pending_before = client.presenter.pending_updates;
    var handler: InputHandler = .{ .client = client };

    const control = try handler.action(configured);

    try std.testing.expect(control == .continue_routing);
    try std.testing.expect(client.model.workspaceListCollapsed());
    try std.testing.expect(client.model.diagnostic() == null);
    var expected = version_before;
    expected.chrome += 1;
    expected.diagnostic += 1;
    try std.testing.expectEqualDeep(expected, client.model.version());
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_before + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expect(client.view.workspace_list_collapsed);
    try std.testing.expectEqual(expected.diagnostic, client.presenter.presented_model_version.diagnostic);
}

test "Lua callback validates every plugin reference before native effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const configured = try installTestingLuaBinding(client,
        \\local telar = require("telar")
        \\return {
        \\  api_version = 2,
        \\  client = { keybindings = {
        \\    telar.bind({ "x" }, function(ctx)
        \\      return {
        \\        telar.action.toggle_sidebar(),
        \\        telar.action.plugin({ plugin = "missing.plugin", action = "run" }),
        \\      }
        \\    end),
        \\  } },
        \\}
    );
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    const version_before = client.model.version();
    const pending_before = client.presenter.pending_updates;
    var handler: InputHandler = .{ .client = client };

    const control = try handler.action(configured);

    try std.testing.expect(control == .continue_routing);
    try std.testing.expect(client.model.sidebarVisible());
    try std.testing.expect(std.mem.indexOf(
        u8,
        client.model.diagnostic().?,
        "PluginNotConfigured",
    ) != null);
    var expected = version_before;
    expected.diagnostic += 1;
    try std.testing.expectEqualDeep(expected, client.model.version());
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_before + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expect(client.view.sidebar_requested);
}

test "Lua expression emits semantic keys through pane input" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const configured = try installTestingLuaBinding(client,
        \\local telar = require("telar")
        \\return {
        \\  api_version = 2,
        \\  client = { keybindings = {
        \\    telar.bind_expr({ "x" }, function(ctx)
        \\      return telar.input.keys({ "left", "enter" })
        \\    end),
        \\  } },
        \\}
    );
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    const version_before = client.model.version();
    const pending_before = client.presenter.pending_updates;
    var handler: InputHandler = .{ .client = client };

    const control = try handler.action(configured);

    try std.testing.expect(control == .continue_routing);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const left = try harness.nextClientMessage(&buffer);
    try std.testing.expect(left == .pane_input);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, left.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x1b[D", left.pane_input.bytes);
    const enter = try harness.nextClientMessage(&buffer);
    try std.testing.expect(enter == .pane_input);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, enter.pane_input.pane_id);
    try std.testing.expectEqualStrings("\r", enter.pane_input.bytes);
}

test "Lua expression paste uses pane modes and copy-mode authority" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.workspace.findPane(TestHarness.bootstrap_pane).?.input_modes.bracketed_paste = true;
    const configured = try installTestingLuaBinding(client,
        \\local telar = require("telar")
        \\return {
        \\  api_version = 2,
        \\  client = { keybindings = {
        \\    telar.bind_expr({ "x" }, function(ctx)
        \\      return telar.input.paste("hello")
        \\    end),
        \\  } },
        \\}
    );
    const version = client.model.version();
    var handler: InputHandler = .{ .client = client };

    try std.testing.expectEqual(keybind.Control.continue_routing, try handler.action(configured));
    try std.testing.expectEqualDeep(version, client.model.version());
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .pane_input);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, message.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x1b[200~hello\x1b[201~", message.pane_input.bytes);

    _ = try client_actions.apply(client, .enter_copy_mode);
    const copy_version = client.model.version();
    const outbox_len = client.runtime_transport.outbox.len;
    try std.testing.expectEqual(keybind.Control.continue_routing, try handler.action(configured));

    try std.testing.expect(client.model.copyModeActive());
    try std.testing.expectEqualDeep(copy_version, client.model.version());
    try std.testing.expectEqual(outbox_len, client.runtime_transport.outbox.len);
}

test "Lua callback failure commits one diagnostic without direct presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const configured = try installTestingLuaBinding(client,
        \\local telar = require("telar")
        \\return {
        \\  api_version = 2,
        \\  client = { keybindings = {
        \\    telar.bind({ "x" }, function(ctx)
        \\      error("callback exploded")
        \\    end),
        \\  } },
        \\}
    );
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    const version_before = client.model.version();
    const pending_before = client.presenter.pending_updates;
    var handler: InputHandler = .{ .client = client };

    const control = try handler.action(configured);

    try std.testing.expect(control == .continue_routing);
    try std.testing.expect(std.mem.indexOf(
        u8,
        client.model.diagnostic().?,
        "callback exploded",
    ) != null);
    var expected = version_before;
    expected.diagnostic += 1;
    try std.testing.expectEqualDeep(expected, client.model.version());
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_before + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(expected.diagnostic, client.presenter.presented_model_version.diagnostic);
}

test "attachment modal captures semantic keys until escape closes it" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const target = try installTestingAttachmentTarget(client, 1);
    const capture = try client.gpa.create(attachments.Capture);
    capture.* = .{
        .request = .{ .target = target, .sequence = 81 },
        .png = try client.gpa.dupe(u8, "png"),
        .width = 2,
        .height = 2,
    };
    var capture_owned = true;
    errdefer if (capture_owned) {
        capture.deinit(client.gpa);
    };
    _ = try client.view.adoptAttachment(capture);
    capture_owned = false;
    const snapshot = client.view.kittyAttachments().snapshot();
    try std.testing.expectEqual(@as(u8, 1), snapshot.len);
    try std.testing.expect(client.view.kittyAttachments().openModal(snapshot.items[0].id));
    const version = client.model.version();
    const interaction_revision = client.view.interactionVersion();
    const pending_updates = client.presenter.pending_updates;
    var handler: InputHandler = .{ .client = client };

    try std.testing.expect(handler.capturesKeys());
    try handler.key(try keybind.parseKey("x"));

    try std.testing.expect(client.view.hasAttachmentModal());
    try std.testing.expectEqual(interaction_revision, client.view.interactionVersion());
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);

    try handler.key(try keybind.parseKey("escape"));

    try std.testing.expect(!client.view.hasAttachmentModal());
    try std.testing.expect(!handler.capturesKeys());
    try std.testing.expectEqual(interaction_revision + 1, client.view.interactionVersion());
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(
        client.view.interactionVersion(),
        client.presenter.presented_presentation_ingress.view_interaction,
    );
}

test "control-v reaches the pane when no clipboard preview target exists" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    var handler: InputHandler = .{ .client = client };

    try handler.key(try keybind.parseKey("ctrl+v"));

    try std.testing.expect(client.model.clipboardCapture() == null);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .pane_input);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, message.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x16", message.pane_input.bytes);
}

test "clipboard image completion publishes resource ingress before presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const target = try installTestingAttachmentTarget(client, 1);
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    const execution = (try client.model.beginClipboardCapture(target)).?;
    const completed = try testingClipboardCapture(client, execution, "png");
    const version_before = client.model.version();
    const pending_before = client.presenter.pending_updates;

    try clipboard_images.complete(client, .{
        .execution_id = execution.id,
        .result = completed,
    });

    try std.testing.expect(client.model.clipboardCapture() == null);
    try std.testing.expect(client.clipboard_capture_resources.orphan == null);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(@as(u64, 1), client.view.kittyAttachments().ingressVersion());
    try std.testing.expectEqual(@as(u8, 1), client.view.kittyAttachments().snapshot().len);
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(u64, 0), client.presenter.observed_attachment_ingress);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_before + 1, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(u64, 1), client.presenter.observed_attachment_ingress);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(@as(u64, 1), client.presenter.presented_attachment_ingress);
}

test "clipboard image from a retired agent target is consumed and freed" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const target = try installTestingAttachmentTarget(client, 1);
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    const execution = (try client.model.beginClipboardCapture(target)).?;
    const completed = try testingClipboardCapture(client, execution, "private png");

    _ = try client.model.reconcileAgentSnapshot(.{ .revision = 2, .agents = &.{} });
    _ = try active_pane_resources.synchronizeAttachments(client);
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    const version_before = client.model.version();
    const pending_before = client.presenter.pending_updates;

    try clipboard_images.complete(client, .{
        .execution_id = execution.id,
        .result = completed,
    });

    try std.testing.expect(client.model.clipboardCapture() == null);
    try std.testing.expect(client.clipboard_capture_resources.orphan == null);
    try std.testing.expectEqual(@as(u64, 0), client.view.kittyAttachments().ingressVersion());
    try std.testing.expectEqual(@as(u8, 0), client.view.kittyAttachments().snapshot().len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);
}

test "clipboard image failures settle lifecycle without direct presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const target = try installTestingAttachmentTarget(client, 1);
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    const pending_before = client.presenter.pending_updates;
    const no_image = (try client.model.beginClipboardCapture(target)).?;
    const version_before_empty = client.model.version();

    try clipboard_images.complete(client, .{
        .execution_id = no_image.id,
        .result = error.NoImageOnClipboard,
    });

    try std.testing.expect(client.model.clipboardCapture() == null);
    try std.testing.expectEqualDeep(version_before_empty, client.model.version());
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);

    const too_large = (try client.model.beginClipboardCapture(target)).?;
    const version_before_large = client.model.version();
    try clipboard_images.complete(client, .{
        .execution_id = too_large.id,
        .result = error.ClipboardImageTooLarge,
    });

    try std.testing.expect(client.model.clipboardCapture() == null);
    try std.testing.expect(client.model.version().notifications > version_before_large.notifications);
    try std.testing.expect(client.notification_scheduler.pending);
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);

    const invalid = (try client.model.beginClipboardCapture(target)).?;
    const completed = try testingClipboardCapture(client, invalid, "invalid");
    completed.width = 0;
    const version_before_invalid = client.model.version();
    try clipboard_images.complete(client, .{
        .execution_id = invalid.id,
        .result = completed,
    });

    try std.testing.expect(client.model.clipboardCapture() == null);
    try std.testing.expect(client.clipboard_capture_resources.orphan == null);
    try std.testing.expect(client.model.version().notifications > version_before_invalid.notifications);
    try std.testing.expectEqual(@as(u64, 0), client.view.kittyAttachments().ingressVersion());
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);
}
