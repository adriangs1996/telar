//! Client integration tests for configuration.

const client_module = @import("telar-client");
const data = @import("model");
const core = @import("telar-core");
const TerminalClient = @import("../TerminalClient.zig");
const TestHarness = @import("TestHarness.zig");
const std = @import("std");
const support = @import("support.zig");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const host_inputs = @import("../controllers/input/host_inputs.zig");

test "config reload outcomes that carry no new generation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;

    try std.testing.expectEqual(
        data.ConfigReloadOutcome.unchanged,
        try client.completeConfigReload(
            .{
                .unchanged = 42,
            },
        ),
    );
    try std.testing.expectEqual(@as(i128, 42), client.reload.mtime_ns);

    var diagnostic: data.Diagnostic = .{};
    diagnostic.set("bad config: {s}", .{"boom"});
    try std.testing.expectEqual(
        data.ConfigReloadOutcome.rejected,
        try client.completeConfigReload(.{ .failed = .{
            .diagnostic = diagnostic,
            .mtime_ns = 7,
        } }),
    );
    try std.testing.expectEqual(@as(i128, 7), client.reload.mtime_ns);
    try std.testing.expect(client.model.notification_scheduler.pending);
    try std.testing.expect(client.model.diagnostic() != null);
    try harness.settle();
}

test "resolved configuration adoption crosses delivery before watcher rearm" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const candidate = try support.testingConfigAdoption(1, false);
    const generation = candidate.generation;

    const outcome = try client.completeConfigReload(.{ .loaded = .{
        .generation = candidate.generation,
        .registry = candidate.registry,
        .trust_store = candidate.trust_store,
        .mtime_ns = 19,
    } });

    try std.testing.expectEqual(@as(u64, 1), outcome.adopted.generation);
    try std.testing.expect(client.lua_generation == generation);
    try std.testing.expectEqual(@as(i128, 19), client.reload.mtime_ns);
    try std.testing.expectEqual(data.Version{
        .configuration = 1,
        .notifications = 1,
    }, client.model.version());
    try std.testing.expect(client.model.notification_scheduler.pending);
    try harness.settle();
}

test "configuration adoption swaps ownership after commit and presents by version" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    var previous_diagnostic: data.Diagnostic = .{};
    previous_diagnostic.set("previous configuration failed", .{});
    _ = try client.model.replaceDiagnostic(previous_diagnostic);
    const initial = try support.testingConfigAdoption(1, false);
    const initial_generation = initial.generation;

    const first = try support.reloadConfiguration(client, initial);

    try std.testing.expectEqual(@as(u64, 1), first.generation);
    try std.testing.expect(client.lua_generation == initial_generation);
    try std.testing.expectEqual(@as(u64, 1), client.model.configuration_generation);
    try std.testing.expect(client.model.diagnostic() == null);

    try std.testing.expectEqualDeep(
        data.SoundRequestOutcome{ .start = .ready },
        client.model.sound_playback.request(.ready),
    );
    try std.testing.expect(client.model.sound_playback.request(.ready) == .queued);
    const pending_updates = TerminalClient.of(client).presenter.pending_updates;
    const changed = try support.testingConfigAdoption(2, true);
    const changed_generation = changed.generation;
    const second = try support.reloadConfiguration(client, changed);

    try std.testing.expectEqual(@as(u64, 2), second.generation);
    try std.testing.expectEqual(@as(u64, 2), second.configuration_revision);
    try std.testing.expect(!second.sidebar.?.visible);
    try std.testing.expect(second.pane_gaps_changed);
    try std.testing.expect(client.lua_generation == changed_generation);
    try std.testing.expectEqual(@as(u64, 2), client.model.configuration_generation);
    try std.testing.expect(!client.model.sidebar_visible);
    try std.testing.expect(!client.model.pane_gaps);
    try std.testing.expect(!TerminalClient.of(client).view.sidebar_requested);
    try std.testing.expectEqualDeep(try data.chord.parseKey("ctrl+s"), TerminalClient.of(client).host_input.router.prefix.?);
    try std.testing.expectEqual(
        @as(u64, 40 * std.time.ns_per_ms),
        TerminalClient.of(client).host_input.router.escape_timeout_ns,
    );
    try std.testing.expectEqual(
        @as(u64, 750 * std.time.ns_per_ms),
        TerminalClient.of(client).host_input.router.sequence_timeout_ns,
    );
    try std.testing.expectEqual(data.SoundSnapshot{
        .configuration = .{ .enabled = false },
        .active = true,
        .queued = null,
    }, client.model.sound_playback.snapshot());
    try std.testing.expectEqual(pending_updates, TerminalClient.of(client).presenter.pending_updates);

    // Check adoption before queued notification ticks can advance its revision.
    try std.testing.expectEqual(data.Version{
        .configuration = 2,
        .diagnostic = 2,
        .notifications = 2,
        .panes = 1,
        .chrome = 1,
    }, client.model.version());

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates + 1, TerminalClient.of(client).presenter.pending_updates);
    std.debug.print(
        "MODEL BEFORE {any}\n",
        .{
            client.model.version(),
        },
    );
    try harness.settleModelPresentation();
    std.debug.print(
        "MODEL AFTER {any}\n",
        .{
            client.model.version(),
        },
    );

    try std.testing.expectEqualDeep(client.model.version(), TerminalClient.of(client).presenter.presentation_state.prepared.model);

    const stale = try support.testingConfigAdoption(2, false);
    try std.testing.expectError(error.StaleConfiguration, support.reloadConfiguration(client, stale));
    try std.testing.expect(client.lua_generation == changed_generation);
    try std.testing.expectEqual(@as(u64, 2), client.model.configuration_generation);
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
    const adoption = try support.testingConfigAdoption(1, true);
    const generation = adoption.generation;

    try std.testing.expectError(error.ClientOutboxFull, support.reloadConfiguration(client, adoption));

    try std.testing.expect(client.lua_generation == generation);
    try std.testing.expectEqual(@as(u64, 1), client.model.configuration_generation);
    try std.testing.expectEqual(@as(u64, 1), client.model.version().configuration);
    try std.testing.expect(!client.model.sidebar_visible);
    try std.testing.expect(!client.model.pane_gaps);
    try harness.deliverHostEffects();
    try std.testing.expect(!TerminalClient.of(client).view.sidebar_requested);
    try std.testing.expectEqual(@as(usize, data.outbox_support.capacity), client.runtime_transport.outbox.len);
}

test "a configuration version alone schedules presenter observation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const pending_updates = TerminalClient.of(client).presenter.pending_updates;

    _ = try client.model.applyConfiguration(.{
        .generation = 1,
        .sidebar_visible = true,
        .pane_gaps = true,
    });

    try std.testing.expectEqual(data.Version{ .configuration = 1 }, client.model.version());
    try std.testing.expectEqual(pending_updates, TerminalClient.of(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates + 1, TerminalClient.of(client).presenter.pending_updates);
    std.debug.print(
        "MODEL BEFORE {any}\n",
        .{
            client.model.version(),
        },
    );
    try harness.settleModelPresentation();
    std.debug.print(
        "MODEL AFTER {any}\n",
        .{
            client.model.version(),
        },
    );

    try std.testing.expectEqualDeep(client.model.version(), TerminalClient.of(client).presenter.presentation_state.prepared.model);
}

test "dynamic bar ticks commit current Lua content before paced presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const adoption = try support.testingConfigAdoptionSource(1,
        \\local telar = require("telar")
        \\local ticks = 0
        \\return { api_version = 2, client = { bars = {
        \\  bottom = {
        \\    left = telar.bar.dynamic({ every_ms = 100, render = function(ctx)
        \\      ticks = ticks + 1
        \\      return { { text = "tick " .. ticks, fg = "teal", bold = true } }
        \\    end }),
        \\    right = telar.bar.tabs(),
        \\  },
        \\} } }
    );
    const pending_before = TerminalClient.of(client).presenter.pending_updates;
    const version_before = client.model.version();

    const commit = try support.reloadConfiguration(client, adoption);

    try std.testing.expect(commit.bars_changed);
    try std.testing.expect(client.model.bar_updates.scheduler.pending);
    const event = try support.receiveClient(client);
    switch (event) {
        .bar_tick => |result| try client_module.operations.bar_updates.handleTick(client, result),
        else => return error.UnexpectedEvent,
    }

    const slot = client.model.bars.layout.slot(.bottom_left);
    try std.testing.expect(slot.* == .content);
    try std.testing.expectEqualStrings("tick 1", slot.content.text(slot.content.slice()[0]));
    try std.testing.expect(slot.content.slice()[0].style.bold);
    var expected_version = version_before;
    expected_version.configuration += 1;
    expected_version.notifications += 1;
    expected_version.bars += 2;
    try std.testing.expectEqualDeep(expected_version, client.model.version());
    try std.testing.expectEqual(pending_before, TerminalClient.of(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_before + 1, TerminalClient.of(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(client.model.version().bars, TerminalClient.of(client).presenter.presentation_state.prepared.model.bars);
}

test "command completion from a replaced bar generation is discarded" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const running = try support.testingConfigAdoptionSource(1,
        \\local telar = require("telar")
        \\return { api_version = 2, client = { bars = { bottom = {
        \\  left = telar.bar.command({
        \\    command = { "/bin/sh", "-c", "sleep 0.2; printf old" },
        \\    every_ms = 1000,
        \\    timeout_ms = 1000,
        \\  }),
        \\  right = telar.bar.tabs(),
        \\} } } }
    );
    _ = try support.reloadConfiguration(client, running);

    const tick = try support.receiveClient(client);
    switch (tick) {
        .bar_tick => |result| try client_module.operations.bar_updates.handleTick(client, result),
        else => return error.UnexpectedEvent,
    }
    try std.testing.expect(client.model.bar_updates.command_execution != null);

    const replacement = try support.testingConfigAdoptionSource(2,
        \\local telar = require("telar")
        \\return { api_version = 2, client = { bars = { bottom = {
        \\  left = telar.bar.static("new"),
        \\  right = telar.bar.tabs(),
        \\} } } }
    );
    _ = try support.reloadConfiguration(client, replacement);
    const completed = while (true) {
        switch (try support.receiveClient(client)) {
            .bar_command => |value| break value,
            .notification_tick => |result| _ = try client.completeNotificationTick(result),
            else => return error.UnexpectedEvent,
        }
    };
    const version_after_reload = client.model.version();
    try client_module.operations.bar_updates.completeCommand(client, completed);

    const slot = client.model.bars.layout.slot(.bottom_left);
    try std.testing.expectEqualStrings("new", slot.content.text(slot.content.slice()[0]));
    try std.testing.expect(client.model.bar_updates.command_execution == null);
    try std.testing.expectEqualDeep(version_after_reload, client.model.version());
    try std.testing.expect(client.model.diagnostic() == null);
}

test "plugin completion applies one authorized batch through model observation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const installed = try support.installTestingPlugin(client);
    const execution = (try client.model.beginPluginExecution()).?;
    var batch: data.EffectBatch = .{};
    batch.items[0] = .toggle_workspace_list;
    batch.len = 1;
    const version_before = client.model.version();
    const pending_before = TerminalClient.of(client).presenter.pending_updates;

    const exit = try client.completePluginAction(.{
        .execution_id = execution.id,
        .result = data.WorkerResult{
            .package_index = 0,
            .plugin_id = installed.action.plugin,
            .digest = installed.digest,
            .batch = batch,
        },
    });

    try std.testing.expect(!exit);
    try std.testing.expect(client.model.plugins.pluginExecution() == null);
    try std.testing.expect(client.model.workspace_list_collapsed);
    try std.testing.expectEqual(version_before.chrome + 1, client.model.version().chrome);
    try std.testing.expectEqual(pending_before, TerminalClient.of(client).presenter.pending_updates);
    try std.testing.expect(!TerminalClient.of(client).view.workspace_list_collapsed);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_before + 1, TerminalClient.of(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expect(TerminalClient.of(client).view.workspace_list_collapsed);
}

test "plugin completion from an old configuration is consumed without effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const installed = try support.installTestingPlugin(client);
    const execution = (try client.model.beginPluginExecution()).?;
    var batch: data.EffectBatch = .{};
    batch.items[0] = .toggle_workspace_list;
    batch.len = 1;

    _ = try client.model.applyConfiguration(.{
        .generation = 1,
        .sidebar_visible = true,
        .pane_gaps = true,
    });
    const version_after_reload = client.model.version();
    const pending_before = TerminalClient.of(client).presenter.pending_updates;

    const exit = try client.completePluginAction(.{
        .execution_id = execution.id,
        .result = data.WorkerResult{
            .package_index = 0,
            .plugin_id = installed.action.plugin,
            .digest = installed.digest,
            .batch = batch,
        },
    });

    try std.testing.expect(!exit);
    try std.testing.expect(client.model.plugins.pluginExecution() == null);
    try std.testing.expect(!client.model.workspace_list_collapsed);
    try std.testing.expectEqualDeep(version_after_reload, client.model.version());
    try std.testing.expect(client.model.diagnostic() == null);
    try std.testing.expectEqual(pending_before, TerminalClient.of(client).presenter.pending_updates);
}

test "plugin authorization denial consumes the run before publishing failure" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const installed = try support.installTestingPlugin(client);
    const execution = (try client.model.beginPluginExecution()).?;
    var batch: data.EffectBatch = .{};
    batch.items[0] = .close_pane;
    batch.len = 1;
    const version_before = client.model.version();
    const pending_before = TerminalClient.of(client).presenter.pending_updates;

    const exit = try client.completePluginAction(.{
        .execution_id = execution.id,
        .result = data.WorkerResult{
            .package_index = 0,
            .plugin_id = installed.action.plugin,
            .digest = installed.digest,
            .batch = batch,
        },
    });

    try std.testing.expect(!exit);
    try std.testing.expect(client.model.plugins.pluginExecution() == null);
    try std.testing.expect(client.model.panes.find(TestHarness.bootstrap_pane) != null);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expect(client.model.version().notifications > version_before.notifications);
    try std.testing.expect(std.mem.indexOf(
        u8,
        client.model.diagnostic().?,
        "CapabilityNotGranted",
    ) != null);
    try std.testing.expect(client.model.notification_scheduler.pending);
    try std.testing.expectEqual(pending_before, TerminalClient.of(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_before + 1, TerminalClient.of(client).presenter.pending_updates);
}

test "plugin worker failure and unmatched completion preserve lifecycle identity" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const execution = (try client.model.beginPluginExecution()).?;

    try std.testing.expect(!try client.completePluginAction(.{
        .execution_id = @enumFromInt(@intFromEnum(execution.id) + 1),
        .result = error.TestPluginWorkerFailure,
    }));
    try std.testing.expectEqualDeep(execution, client.model.plugins.pluginExecution().?);
    try std.testing.expect(client.model.diagnostic() == null);

    try std.testing.expect(!try client.completePluginAction(.{
        .execution_id = execution.id,
        .result = error.TestPluginWorkerFailure,
    }));
    try std.testing.expect(client.model.plugins.pluginExecution() == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        client.model.diagnostic().?,
        "TestPluginWorkerFailure",
    ) != null);
    try std.testing.expect(client.model.notification_scheduler.pending);
}

test "busy plugin start skips resolution and a rejected action leaves no run" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const installed = try support.installTestingPlugin(client);
    const execution = (try client.model.beginPluginExecution()).?;

    _ = try client.executeAction(
        .{
            .plugin = installed.action,
        },
        .binding,
    );

    try std.testing.expectEqualDeep(execution, client.model.plugins.pluginExecution().?);
    _ = client.model.plugins.finishPluginExecution(execution.id);

    _ = try client.executeAction(
        .{
            .plugin = .{
                .plugin = installed.action.plugin,
                .action = core.stableId("missing"),
            },
        },
        .binding,
    );

    try std.testing.expect(client.model.plugins.pluginExecution() == null);
    try std.testing.expect(client.model.notification_scheduler.pending);
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
    try std.testing.expect(client.openNamePrompt(.rename_active_tab));
    const version = client.model.version();
    const outbox_len = client.runtime_transport.outbox.len;

    const suppressed = [_]data.Action{
        .toggle_sidebar,
        .{ .lua_callback = .{ .generation = 1, .id = 1 } },
        .{ .lua_expr = .{ .generation = 1, .id = 1 } },
        .{ .plugin = .{ .plugin = 1, .action = 1 } },
    };
    for (suppressed) |action| {
        const control = try client.executeAction(action, .binding);
        try std.testing.expect(control == .continue_routing);
        try std.testing.expect(client.model.name_prompt.active());
        try std.testing.expect(client.model.sidebar_visible);
        try std.testing.expectEqualDeep(version, client.model.version());
        try std.testing.expectEqual(outbox_len, client.runtime_transport.outbox.len);
    }
}

test "validated native effects preserve their authority while a name prompt is open" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    try std.testing.expect(client.openNamePrompt(.rename_active_tab));
    try std.testing.expect(client.model.sidebar_visible);

    _ = try client.executeAction(.toggle_sidebar, .binding);
    try std.testing.expect(client.model.sidebar_visible);
    _ = try client.executeAction(.toggle_sidebar, .effect);
    try std.testing.expect(!client.model.sidebar_visible);
    try std.testing.expect(client.model.name_prompt.active());
}

test "Lua callback applies a validated batch through model observation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const configured = try support.installTestingLuaBinding(client,
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
    const pending_before = TerminalClient.of(client).presenter.pending_updates;

    const control = try client.executeAction(configured, .binding);

    try std.testing.expect(control == .continue_routing);
    try std.testing.expect(client.model.workspace_list_collapsed);
    try std.testing.expect(client.model.diagnostic() == null);
    var expected = version_before;
    expected.chrome += 1;
    expected.diagnostic += 1;
    try std.testing.expectEqualDeep(expected, client.model.version());
    try std.testing.expectEqual(pending_before, TerminalClient.of(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_before + 1, TerminalClient.of(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expect(TerminalClient.of(client).view.workspace_list_collapsed);
    try std.testing.expectEqual(expected.diagnostic, TerminalClient.of(client).presenter.presentation_state.prepared.model.diagnostic);
}

test "Lua callback validates every plugin reference before native effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const configured = try support.installTestingLuaBinding(client,
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
    const pending_before = TerminalClient.of(client).presenter.pending_updates;

    const control = try client.executeAction(configured, .binding);

    try std.testing.expect(control == .continue_routing);
    try std.testing.expect(client.model.sidebar_visible);
    try std.testing.expect(std.mem.indexOf(
        u8,
        client.model.diagnostic().?,
        "PluginNotConfigured",
    ) != null);
    var expected = version_before;
    expected.diagnostic += 1;
    try std.testing.expectEqualDeep(expected, client.model.version());
    try std.testing.expectEqual(pending_before, TerminalClient.of(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_before + 1, TerminalClient.of(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expect(TerminalClient.of(client).view.sidebar_requested);
}

test "Lua expression emits semantic keys through pane input" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const configured = try support.installTestingLuaBinding(client,
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
    const pending_before = TerminalClient.of(client).presenter.pending_updates;

    const control = try client.executeAction(configured, .binding);

    try std.testing.expect(control == .continue_routing);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_before, TerminalClient.of(client).presenter.pending_updates);
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
    client.model.panes.find(TestHarness.bootstrap_pane).?.input_modes.bracketed_paste = true;
    const configured = try support.installTestingLuaBinding(client,
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

    try std.testing.expectEqual(data.KeybindControl.continue_routing, try client.executeAction(configured, .binding));
    try std.testing.expectEqualDeep(version, client.model.version());
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .pane_input);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, message.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x1b[200~hello\x1b[201~", message.pane_input.bytes);

    _ = try client.executeAction(.enter_copy_mode, .effect);
    const copy_version = client.model.version();
    const outbox_len = client.runtime_transport.outbox.len;
    try std.testing.expectEqual(data.KeybindControl.continue_routing, try client.executeAction(configured, .binding));

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
    const configured = try support.installTestingLuaBinding(client,
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
    const pending_before = TerminalClient.of(client).presenter.pending_updates;

    const control = try client.executeAction(configured, .binding);

    try std.testing.expect(control == .continue_routing);
    try std.testing.expect(std.mem.indexOf(
        u8,
        client.model.diagnostic().?,
        "callback exploded",
    ) != null);
    var expected = version_before;
    expected.diagnostic += 1;
    try std.testing.expectEqualDeep(expected, client.model.version());
    try std.testing.expectEqual(pending_before, TerminalClient.of(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_before + 1, TerminalClient.of(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(expected.diagnostic, TerminalClient.of(client).presenter.presentation_state.prepared.model.diagnostic);
}

test "attachment modal captures semantic keys until escape closes it" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const target = try support.installTestingAttachmentTarget(client, 1);
    const capture = try client.gpa.create(data.Capture);
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
    _ = try TerminalClient.of(client).view.adoptAttachment(capture);
    capture_owned = false;
    const snapshot = TerminalClient.of(client).view.kittyAttachments().snapshot();
    try std.testing.expectEqual(@as(u8, 1), snapshot.len);
    try std.testing.expect(TerminalClient.of(client).view.kittyAttachments().openModal(snapshot.items[0].id));
    const version = client.model.version();
    const interaction_revision = TerminalClient.of(client).view.interactionVersion();
    const pending_updates = TerminalClient.of(client).presenter.pending_updates;

    try std.testing.expect(data.key_routing.captures(client.keyRoutingAuthority()));
    try host_inputs.key(client, try data.chord.parseKey("x"));

    try std.testing.expect(TerminalClient.of(client).view.hasAttachmentModal());
    try std.testing.expectEqual(interaction_revision, TerminalClient.of(client).view.interactionVersion());
    try std.testing.expectEqual(pending_updates, TerminalClient.of(client).presenter.pending_updates);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);

    try host_inputs.key(client, try data.chord.parseKey("escape"));

    try std.testing.expect(!TerminalClient.of(client).view.hasAttachmentModal());
    try std.testing.expect(!data.key_routing.captures(client.keyRoutingAuthority()));
    try std.testing.expectEqual(interaction_revision + 1, TerminalClient.of(client).view.interactionVersion());
    try std.testing.expectEqual(pending_updates, TerminalClient.of(client).presenter.pending_updates);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates + 1, TerminalClient.of(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(
        TerminalClient.of(client).view.interactionVersion(),
        TerminalClient.of(client).presenter.presentation_state.prepared.presentation_ingress.view_interaction,
    );
}

test "control-v reaches the pane when no clipboard preview target exists" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    try host_inputs.key(client, try data.chord.parseKey("ctrl+v"));

    try std.testing.expect(client.model.clipboard.capture == null);
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
    const target = try support.installTestingAttachmentTarget(client, 1);
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    const execution = (try client.model.clipboard.reserve(target)).?;
    const completed = try support.testingClipboardCapture(client, execution, "png");
    const version_before = client.model.version();
    const pending_before = TerminalClient.of(client).presenter.pending_updates;

    try client.completeClipboardCapture(.{
        .execution_id = execution.id,
        .result = completed,
    });

    try std.testing.expect(client.model.clipboard.capture == null);
    try std.testing.expect(client.model.clipboard.orphan == null);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(@as(u64, 1), TerminalClient.of(client).view.kittyAttachments().ingressVersion());
    try std.testing.expectEqual(@as(u8, 1), TerminalClient.of(client).view.kittyAttachments().snapshot().len);
    try std.testing.expectEqual(pending_before, TerminalClient.of(client).presenter.pending_updates);
    try std.testing.expectEqual(@as(u64, 0), TerminalClient.of(client).presenter.presentation_state.observed.attachment_ingress);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_before + 1, TerminalClient.of(client).presenter.pending_updates);
    try std.testing.expectEqual(@as(u64, 1), TerminalClient.of(client).presenter.presentation_state.observed.attachment_ingress);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(@as(u64, 1), TerminalClient.of(client).presenter.presentation_state.prepared.attachment_ingress);
}

test "clipboard image from a retired agent target is consumed and freed" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const target = try support.installTestingAttachmentTarget(client, 1);
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    const execution = (try client.model.clipboard.reserve(target)).?;
    const completed = try support.testingClipboardCapture(client, execution, "private png");

    _ = try client.model.reconcileAgentSnapshot(.{ .revision = 2, .agents = &.{} });
    _ = try client.synchronizePaneAttachments();
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    const version_before = client.model.version();
    const pending_before = TerminalClient.of(client).presenter.pending_updates;

    try client.completeClipboardCapture(.{
        .execution_id = execution.id,
        .result = completed,
    });

    try std.testing.expect(client.model.clipboard.capture == null);
    try std.testing.expect(client.model.clipboard.orphan == null);
    try std.testing.expectEqual(@as(u64, 0), TerminalClient.of(client).view.kittyAttachments().ingressVersion());
    try std.testing.expectEqual(@as(u8, 0), TerminalClient.of(client).view.kittyAttachments().snapshot().len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_before, TerminalClient.of(client).presenter.pending_updates);
}

test "clipboard image failures settle lifecycle without direct presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const target = try support.installTestingAttachmentTarget(client, 1);
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    const pending_before = TerminalClient.of(client).presenter.pending_updates;
    const no_image = (try client.model.clipboard.reserve(target)).?;
    const version_before_empty = client.model.version();

    try client.completeClipboardCapture(.{
        .execution_id = no_image.id,
        .result = error.NoImageOnClipboard,
    });

    try std.testing.expect(client.model.clipboard.capture == null);
    try std.testing.expectEqualDeep(version_before_empty, client.model.version());
    try std.testing.expectEqual(pending_before, TerminalClient.of(client).presenter.pending_updates);

    const too_large = (try client.model.clipboard.reserve(target)).?;
    const version_before_large = client.model.version();
    try client.completeClipboardCapture(.{
        .execution_id = too_large.id,
        .result = error.ClipboardImageTooLarge,
    });

    try std.testing.expect(client.model.clipboard.capture == null);
    try std.testing.expect(client.model.version().notifications > version_before_large.notifications);
    try std.testing.expect(client.model.notification_scheduler.pending);
    try std.testing.expectEqual(pending_before, TerminalClient.of(client).presenter.pending_updates);

    const invalid = (try client.model.clipboard.reserve(target)).?;
    const completed = try support.testingClipboardCapture(client, invalid, "invalid");
    completed.width = 0;
    const version_before_invalid = client.model.version();
    try client.completeClipboardCapture(.{
        .execution_id = invalid.id,
        .result = completed,
    });

    try std.testing.expect(client.model.clipboard.capture == null);
    try std.testing.expect(client.model.clipboard.orphan == null);
    try std.testing.expect(client.model.version().notifications > version_before_invalid.notifications);
    try std.testing.expectEqual(@as(u64, 0), TerminalClient.of(client).view.kittyAttachments().ingressVersion());
    try std.testing.expectEqual(pending_before, TerminalClient.of(client).presenter.pending_updates);
}

test "configuration watch rejects incomplete ownership before starting a worker" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.reload.force_next = true;
    try client.scheduleConfigReload();
    try std.testing.expect(client.reload.force_next);

    client.options.config_path = "/unused/config.lua";
    try std.testing.expectError(error.ConfigurationNotLoaded, client.scheduleConfigReload());
    client.options.trust_path = "/unused/trust.json";
    try std.testing.expectError(error.ConfigurationNotLoaded, client.scheduleConfigReload());
    client.options.config_path = null;
    _ = try support.reloadConfiguration(client, try support.testingConfigAdoption(1, false));
    client.options.config_path = "/unused/config.lua";
    const registry = client.plugin_registry;
    client.plugin_registry = null;
    defer client.plugin_registry = registry;
    try std.testing.expectError(error.ConfigurationNotLoaded, client.scheduleConfigReload());
    try std.testing.expect(client.reload.force_next);
}

test "bar configuration excludes Lua sources from a different model generation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    try std.testing.expect(client.barConfiguration() == null);
    try client.synchronizeBars();
    try std.testing.expect(client.model.bar_updates.nextDeadline() == null);
    try std.testing.expect(!client.model.bar_updates.scheduler.pending);

    _ = try support.reloadConfiguration(client, try support.testingConfigAdoption(1, false));
    const generation = client.lua_generation.?;
    try std.testing.expect(client.barConfiguration() == &generation.snapshot.bars);
    const snapshot = &generation.snapshot;
    _ = try client.model.applyConfiguration(
        .{
            .generation = generation.number + 1,
            .sidebar_visible = snapshot.sidebar_visible,
            .pane_gaps = snapshot.pane_gaps,
            .window_title = snapshot.windowTitle(),
            .bars = snapshot.bars.presentation(),
        },
    );
    try std.testing.expect(client.barConfiguration() == null);
    client.model.bar_updates.pending_callbacks = data.bar_values.Position.bottom_left.bit();
    try client.synchronizeBars();
    try std.testing.expectEqual(@as(u8, 0), client.model.bar_updates.pending_callbacks);
    try std.testing.expect(client.model.bar_updates.nextDeadline() == null);
    try std.testing.expect(!client.model.bar_updates.scheduler.pending);
}

test "the configuration a client starts with governs history and notifications before any reload" {
    var diagnostic: data.Diagnostic = .{};
    const generation = try client_module.Generation.loadSource(
        .{
            .gpa = std.testing.allocator,
            .io = std.testing.io,
            .diagnostic = &diagnostic,
        },
        .{
            .source = "return { api_version = 2, client = { history = { match = 'fts', enter = 'run', show_agent_commands = true }, notifications = { delivery = 'system' } } }",
            .source_name = "@config.lua",
            .number = 1,
        },
    );
    var harness: TestHarness = undefined;
    try harness.initWithOptions(false, .{
        .arguments = &.{},
        .cwd = "/",
        .endpoint = "",
        .lua_generation = generation,
    });
    defer harness.deinit();

    const config = harness.client.model.config;
    try std.testing.expect(config.history_match_fts);
    try std.testing.expect(config.history_enter_runs);
    try std.testing.expect(config.history_show_agent_commands);
    try std.testing.expectEqual(data.NotificationDelivery.system, config.notification_delivery);
}
