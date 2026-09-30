//! Client integration tests for configuration.
const keyinput = @import("keyinput");

const client_module = @import("telar-client");
const data = @import("model");
const core = @import("telar-core");
const ClientHarness = @import("ClientHarness.zig");
const std = @import("std");
const fixtures = @import("fixtures.zig");
const PreviewShelf = @import("PreviewShelf.zig");

test "config reload outcomes that carry no new generation" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;

    try std.testing.expectEqual(
        data.ConfigReloadOutcome.unchanged,
        try client_module.config_adoption.completeConfigReload(
            client,
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
        try client_module.config_adoption.completeConfigReload(client, .{ .failed = .{
            .diagnostic = diagnostic,
            .mtime_ns = 7,
        } }),
    );
    try std.testing.expectEqual(@as(i128, 7), client.reload.mtime_ns);
    try std.testing.expect(client.model.notification_scheduler.pending);
    try std.testing.expect(data.client_diagnostic.shown(&client.model) != null);
    try harness.settle();
}

test "resolved configuration adoption crosses delivery before watcher rearm" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const candidate = try fixtures.testingConfigAdoption(1, false);
    const generation = candidate.generation;

    const outcome = try client_module.config_adoption.completeConfigReload(client, .{ .loaded = .{
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
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    var previous_diagnostic: data.Diagnostic = .{};
    previous_diagnostic.set("previous configuration failed", .{});
    _ = try data.client_diagnostic.replace(&client.model, previous_diagnostic);
    const initial = try fixtures.testingConfigAdoption(1, false);
    const initial_generation = initial.generation;

    const first = try fixtures.reloadConfiguration(&harness, initial);

    try std.testing.expectEqual(@as(u64, 1), first.generation);
    try std.testing.expect(client.lua_generation == initial_generation);
    try std.testing.expectEqual(@as(u64, 1), client.model.configuration_generation);
    try std.testing.expect(data.client_diagnostic.shown(&client.model) == null);

    try std.testing.expectEqualDeep(
        data.SoundRequestOutcome{ .start = .ready },
        client.model.sound_playback.request(.ready),
    );
    try std.testing.expect(client.model.sound_playback.request(.ready) == .queued);
    const observed_before = client.presentation.observed;
    const changed = try fixtures.testingConfigAdoption(2, true);
    const changed_generation = changed.generation;
    const second = try fixtures.reloadConfiguration(&harness, changed);

    try std.testing.expectEqual(@as(u64, 2), second.generation);
    try std.testing.expectEqual(@as(u64, 2), second.configuration_revision);
    try std.testing.expect(!second.sidebar.?.visible);
    try std.testing.expect(second.pane_gaps_changed);
    try std.testing.expect(client.lua_generation == changed_generation);
    try std.testing.expectEqual(@as(u64, 2), client.model.configuration_generation);
    try std.testing.expect(!client.model.sidebar_visible);
    try std.testing.expect(!client.model.pane_gaps);
    const router = client.routerConfig();
    try std.testing.expectEqualDeep(try keyinput.chord.parseKey("ctrl+s"), router.prefix);
    try std.testing.expectEqual(
        @as(u64, 750 * std.time.ns_per_ms),
        router.sequence_timeout_ns,
    );
    try std.testing.expectEqual(data.SoundSnapshot{
        .configuration = .{ .enabled = false },
        .active = true,
        .queued = null,
    }, client.model.sound_playback.snapshot());
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);

    // Check adoption before queued notification ticks can advance its revision.
    try std.testing.expectEqual(data.Version{
        .configuration = 2,
        .diagnostic = 2,
        .notifications = 2,
        .panes = 1,
        .chrome = 1,
    }, client.model.version());

    try harness.settleModelPresentation();

    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);

    const stale = try fixtures.testingConfigAdoption(2, false);
    try std.testing.expectError(error.StaleConfiguration, fixtures.reloadConfiguration(&harness, stale));
    try std.testing.expect(client.lua_generation == changed_generation);
    try std.testing.expectEqual(@as(u64, 2), client.model.configuration_generation);
}

test "configuration adoption keeps new ownership after geometry failure" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    while (client.model.to_runtime.hasCapacity()) {
        try client.model.to_runtime.push(.{ .detach_pane = .{ .pane_id = ClientHarness.bootstrap_pane } });
    }
    const adoption = try fixtures.testingConfigAdoption(1, true);
    const generation = adoption.generation;

    try std.testing.expectError(error.ClientOutboxFull, fixtures.reloadConfiguration(&harness, adoption));

    try std.testing.expect(client.lua_generation == generation);
    try std.testing.expectEqual(@as(u64, 1), client.model.configuration_generation);
    try std.testing.expectEqual(@as(u64, 1), client.model.version().configuration);
    try std.testing.expect(!client.model.sidebar_visible);
    try std.testing.expect(!client.model.pane_gaps);
    try harness.deliverHostEffects();
    try std.testing.expect(!client.model.sidebar_visible);
    try std.testing.expectEqual(@as(usize, data.outbox_support.capacity), client.model.to_runtime.len);
}

test "a configuration version alone schedules presenter observation" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const observed_before = client.presentation.observed;

    _ = try data.config_reload.apply(&client.model, .{
        .generation = 1,
        .sidebar_visible = true,
        .pane_gaps = true,
    });

    try std.testing.expectEqual(data.Version{ .configuration = 1 }, client.model.version());
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);

    try harness.settleModelPresentation();

    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);
}

test "dynamic bar ticks commit current Lua content before paced presentation" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const adoption = try fixtures.testingConfigAdoptionSource(1,
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
    const observed_before = client.presentation.observed;
    const version_before = client.model.version();

    const commit = try fixtures.reloadConfiguration(&harness, adoption);

    try std.testing.expect(commit.bars_changed);
    try std.testing.expect(client.model.bar_updates.scheduler.pending);
    const event = try harness.receiveClient();
    switch (event) {
        .bar_tick => |result| try client_module.bar_updates.handleTick(client, result),
        else => return error.UnexpectedEvent,
    }

    const slot = client.model.bars.layout.slot(.bottom_left);
    try std.testing.expect(slot.* == .content);
    try std.testing.expectEqualStrings("tick 1", slot.content.text(slot.content.slice()[0].text));
    try std.testing.expect(slot.content.slice()[0].style.bold);
    var expected_version = version_before;
    expected_version.configuration += 1;
    expected_version.notifications += 1;
    expected_version.bars += 2;
    try std.testing.expectEqualDeep(expected_version, client.model.version());
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);

    try harness.settleModelPresentation();
    try std.testing.expectEqual(client.model.version().bars, client.presentation.prepared.model.bars);
}

test "a bar with five click actions says why it failed and its next render clears that" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const adoption = try fixtures.testingConfigAdoptionSource(1,
        \\local telar = require("telar")
        \\local ui = telar.ui
        \\local ticks = 0
        \\return { api_version = 2, client = { bars = {
        \\  bottom = {
        \\    left = telar.bar.dynamic({ every_ms = 100, render = function()
        \\      ticks = ticks + 1
        \\      local items = {}
        \\      for index = 1, ticks == 1 and 5 or 1 do
        \\        items[#items + 1] = ui.group({ on_click = telar.action.toggle_sidebar(), ui.label("b" .. index) })
        \\      end
        \\      return items
        \\    end }),
        \\    right = telar.bar.tabs(),
        \\  },
        \\} } }
    );
    _ = try fixtures.reloadConfiguration(&harness, adoption);

    switch (try harness.receiveClient()) {
        .bar_tick => |result| try client_module.bar_updates.handleTick(client, result),
        else => return error.UnexpectedEvent,
    }
    try std.testing.expectEqualStrings("invalid telar.ui.group: TooManyBarActions", data.client_diagnostic.shown(&client.model).?);
    try std.testing.expectEqual(data.bar_values.Position.bottom_left, client.model.bar_updates.failed_position.?);

    switch (try harness.receiveClient()) {
        .bar_tick => |result| try client_module.bar_updates.handleTick(client, result),
        else => return error.UnexpectedEvent,
    }
    try std.testing.expect(data.client_diagnostic.shown(&client.model) == null);
    try std.testing.expect(client.model.bar_updates.failed_position == null);
}

test "a failed panel keeps its reason and a later render clears the diagnostic it left" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const adoption = try fixtures.testingConfigAdoptionSource(1,
        \\local telar = require("telar")
        \\local ui = telar.ui
        \\local renders = 0
        \\return { api_version = 2, client = {
        \\  panels = {
        \\    usage = telar.panel({ title = "Usage", render = function()
        \\      renders = renders + 1
        \\      if renders == 1 then error("usage file missing") end
        \\      return ui.heading("On track")
        \\    end }),
        \\  },
        \\  bars = { bottom = {
        \\    left = telar.bar.static({ ui.group({ on_click = telar.action.open_panel("usage"), ui.label("usage") }) }),
        \\    right = telar.bar.tabs(),
        \\  } },
        \\} }
    );
    _ = try fixtures.reloadConfiguration(&harness, adoption);
    try harness.settleModelPresentation();

    const component: data.BarComponent = .{ .position = .bottom_left, .node = 0 };
    _ = try client_module.view_interactions.apply(client, client.model.tabs.active, .{
        .intent = .{ .bar_component = component },
        .consumed = true,
    });
    switch (try harness.receiveClient()) {
        .bar_tick => |result| try client_module.bar_updates.handleTick(client, result),
        else => return error.UnexpectedEvent,
    }
    const panel = &client.model.bars.panel;
    try std.testing.expectEqual(data.PanelStatus.failed, panel.status);
    try std.testing.expect(std.mem.indexOf(u8, panel.reason.message(), "usage file missing") != null);
    try std.testing.expectEqualStrings(panel.reason.message(), data.client_diagnostic.shown(&client.model).?);

    try client_module.bar_updates.refreshPanel(client);
    switch (try harness.receiveClient()) {
        .bar_tick => |result| try client_module.bar_updates.handleTick(client, result),
        else => return error.UnexpectedEvent,
    }
    try std.testing.expectEqual(data.PanelStatus.ready, panel.status);
    try std.testing.expect(data.client_diagnostic.shown(&client.model) == null);
    try std.testing.expect(client.model.bar_updates.panel_failed_revision == null);
}

test "command completion from a replaced bar generation is discarded" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const running = try fixtures.testingConfigAdoptionSource(1,
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
    _ = try fixtures.reloadConfiguration(&harness, running);

    const tick = try harness.receiveClient();
    switch (tick) {
        .bar_tick => |result| try client_module.bar_updates.handleTick(client, result),
        else => return error.UnexpectedEvent,
    }
    try std.testing.expect(client.model.bar_updates.command_execution != null);

    const replacement = try fixtures.testingConfigAdoptionSource(2,
        \\local telar = require("telar")
        \\return { api_version = 2, client = { bars = { bottom = {
        \\  left = telar.bar.static("new"),
        \\  right = telar.bar.tabs(),
        \\} } } }
    );
    _ = try fixtures.reloadConfiguration(&harness, replacement);
    const completed = while (true) {
        switch (try harness.receiveClient()) {
            .bar_command => |value| break value,
            .notification_tick => |result| _ = try client_module.notifications.completeNotificationTick(client, result),
            else => return error.UnexpectedEvent,
        }
    };
    const version_after_reload = client.model.version();
    try client_module.bar_updates.completeCommand(client, completed);

    const slot = client.model.bars.layout.slot(.bottom_left);
    try std.testing.expectEqualStrings("new", slot.content.text(slot.content.slice()[0].text));
    try std.testing.expect(client.model.bar_updates.command_execution == null);
    try std.testing.expectEqualDeep(version_after_reload, client.model.version());
    try std.testing.expect(data.client_diagnostic.shown(&client.model) == null);
}

test "plugin completion applies one authorized batch through model observation" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const installed = try fixtures.installTestingPlugin(client);
    const execution = (try data.plugin_action.beginExecution(&client.model)).?;
    var batch: data.EffectBatch = .{};
    batch.items[0] = .toggle_workspace_list;
    batch.len = 1;
    const version_before = client.model.version();
    const observed_before = client.presentation.observed;

    client.plugin_result = .{
        .package_index = 0,
        .plugin_id = installed.action.plugin,
        .digest = installed.digest,
        .batch = batch,
    };
    const exit = try client_module.plugin_actions.completePluginAction(
        client,
        .{
            .execution_id = execution.id,
            .result = {},
        },
    );

    try std.testing.expect(!exit);
    try std.testing.expect(client.model.plugins.pluginExecution() == null);
    try std.testing.expect(client.model.workspace_list_collapsed);
    try std.testing.expectEqual(version_before.chrome + 1, client.model.version().chrome);
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);

    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);
    try std.testing.expect(client.model.workspace_list_collapsed);
}

test "plugin completion from an old configuration is consumed without effects" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const installed = try fixtures.installTestingPlugin(client);
    const execution = (try data.plugin_action.beginExecution(&client.model)).?;
    var batch: data.EffectBatch = .{};
    batch.items[0] = .toggle_workspace_list;
    batch.len = 1;

    _ = try data.config_reload.apply(&client.model, .{
        .generation = 1,
        .sidebar_visible = true,
        .pane_gaps = true,
    });
    const version_after_reload = client.model.version();
    const observed_before = client.presentation.observed;

    client.plugin_result = .{
        .package_index = 0,
        .plugin_id = installed.action.plugin,
        .digest = installed.digest,
        .batch = batch,
    };
    const exit = try client_module.plugin_actions.completePluginAction(
        client,
        .{
            .execution_id = execution.id,
            .result = {},
        },
    );

    try std.testing.expect(!exit);
    try std.testing.expect(client.model.plugins.pluginExecution() == null);
    try std.testing.expect(!client.model.workspace_list_collapsed);
    try std.testing.expectEqualDeep(version_after_reload, client.model.version());
    try std.testing.expect(data.client_diagnostic.shown(&client.model) == null);
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);
}

test "plugin authorization denial consumes the run before publishing failure" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const installed = try fixtures.installTestingPlugin(client);
    const execution = (try data.plugin_action.beginExecution(&client.model)).?;
    var batch: data.EffectBatch = .{};
    batch.items[0] = .close_pane;
    batch.len = 1;
    const version_before = client.model.version();
    const observed_before = client.presentation.observed;

    client.plugin_result = .{
        .package_index = 0,
        .plugin_id = installed.action.plugin,
        .digest = installed.digest,
        .batch = batch,
    };
    const exit = try client_module.plugin_actions.completePluginAction(
        client,
        .{
            .execution_id = execution.id,
            .result = {},
        },
    );

    try std.testing.expect(!exit);
    try std.testing.expect(client.model.plugins.pluginExecution() == null);
    try std.testing.expect(client.model.panes.find(ClientHarness.bootstrap_pane) != null);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
    try std.testing.expect(client.model.version().notifications > version_before.notifications);
    try std.testing.expect(std.mem.indexOf(
        u8,
        data.client_diagnostic.shown(&client.model).?,
        "CapabilityNotGranted",
    ) != null);
    try std.testing.expect(client.model.notification_scheduler.pending);
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);

    try harness.present();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);
}

test "plugin worker failure and unmatched completion preserve lifecycle identity" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const execution = (try data.plugin_action.beginExecution(&client.model)).?;

    try std.testing.expect(!try client_module.plugin_actions.completePluginAction(client, .{
        .execution_id = @enumFromInt(@intFromEnum(execution.id) + 1),
        .result = error.TestPluginWorkerFailure,
    }));
    try std.testing.expectEqualDeep(execution, client.model.plugins.pluginExecution().?);
    try std.testing.expect(data.client_diagnostic.shown(&client.model) == null);

    try std.testing.expect(!try client_module.plugin_actions.completePluginAction(client, .{
        .execution_id = execution.id,
        .result = error.TestPluginWorkerFailure,
    }));
    try std.testing.expect(client.model.plugins.pluginExecution() == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        data.client_diagnostic.shown(&client.model).?,
        "TestPluginWorkerFailure",
    ) != null);
    try std.testing.expect(client.model.notification_scheduler.pending);
}

test "busy plugin start skips resolution and a rejected action leaves no run" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const installed = try fixtures.installTestingPlugin(client);
    const execution = (try data.plugin_action.beginExecution(&client.model)).?;

    _ = try client_module.actions.executeAction(
        client,
        .{
            .plugin = installed.action,
        },
        .binding,
    );

    try std.testing.expectEqualDeep(execution, client.model.plugins.pluginExecution().?);
    _ = client.model.plugins.finishPluginExecution(execution.id);

    _ = try client_module.actions.executeAction(
        client,
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
        data.client_diagnostic.shown(&client.model).?,
        "UnknownPluginAction",
    ) != null);
}

test "name prompt suppresses a configured action before source dispatch" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    try std.testing.expect(client_module.name_prompt.openNamePrompt(&client.model, .rename_active_tab));
    const version = client.model.version();
    const outbox_len = client.model.to_runtime.len;

    const suppressed = [_]data.Action{
        .toggle_sidebar,
        .{ .lua_callback = .{ .generation = 1, .id = 1 } },
        .{ .lua_expr = .{ .generation = 1, .id = 1 } },
        .{ .plugin = .{ .plugin = 1, .action = 1 } },
    };
    for (suppressed) |action| {
        const control = try client_module.actions.executeAction(client, action, .binding);
        try std.testing.expect(control == .continue_routing);
        try std.testing.expect(client.model.name_prompt.active());
        try std.testing.expect(client.model.sidebar_visible);
        try std.testing.expectEqualDeep(version, client.model.version());
        try std.testing.expectEqual(outbox_len, client.model.to_runtime.len);
    }
}

test "validated native effects preserve their authority while a name prompt is open" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    try std.testing.expect(client_module.name_prompt.openNamePrompt(&client.model, .rename_active_tab));
    try std.testing.expect(client.model.sidebar_visible);

    _ = try client_module.actions.executeAction(client, .toggle_sidebar, .binding);
    try std.testing.expect(client.model.sidebar_visible);
    _ = try client_module.actions.executeAction(client, .toggle_sidebar, .effect);
    try std.testing.expect(!client.model.sidebar_visible);
    try std.testing.expect(client.model.name_prompt.active());
}

test "Lua callback applies a validated batch through model observation" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const configured = try fixtures.installTestingLuaBinding(&harness,
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
    try harness.settleModelPresentation();
    _ = try data.client_diagnostic.set(&client.model, "old diagnostic", .{});
    try harness.settleModelPresentation();
    const version_before = client.model.version();
    const observed_before = client.presentation.observed;

    const control = try client_module.actions.executeAction(client, configured, .binding);

    try std.testing.expect(control == .continue_routing);
    try std.testing.expect(client.model.workspace_list_collapsed);
    try std.testing.expect(data.client_diagnostic.shown(&client.model) == null);
    var expected = version_before;
    expected.chrome += 1;
    expected.diagnostic += 1;
    try std.testing.expectEqualDeep(expected, client.model.version());
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);

    try harness.settleModelPresentation();
    try std.testing.expectEqual(expected.diagnostic, client.presentation.prepared.model.diagnostic);
}

test "Lua callback validates every plugin reference before native effects" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const configured = try fixtures.installTestingLuaBinding(&harness,
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
    try harness.settleModelPresentation();
    const version_before = client.model.version();
    const observed_before = client.presentation.observed;

    const control = try client_module.actions.executeAction(client, configured, .binding);

    try std.testing.expect(control == .continue_routing);
    try std.testing.expect(client.model.sidebar_visible);
    try std.testing.expect(std.mem.indexOf(
        u8,
        data.client_diagnostic.shown(&client.model).?,
        "PluginNotConfigured",
    ) != null);
    var expected = version_before;
    expected.diagnostic += 1;
    try std.testing.expectEqualDeep(expected, client.model.version());
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);

    try harness.settleModelPresentation();
    try std.testing.expectEqual(expected.diagnostic, client.presentation.prepared.model.diagnostic);
}

test "Lua expression emits semantic keys through pane input" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const configured = try fixtures.installTestingLuaBinding(&harness,
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
    try harness.settleModelPresentation();
    const version_before = client.model.version();
    const observed_before = client.presentation.observed;

    const control = try client_module.actions.executeAction(client, configured, .binding);

    try std.testing.expect(control == .continue_routing);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    // Both keys leave in the event's one write, coalesced into one input.
    const keys = try harness.nextClientMessage(&buffer);
    try std.testing.expect(keys == .pane_input);
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, keys.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x1b[D\r", keys.pane_input.bytes);
}

test "Lua expression paste uses pane modes and copy-mode authority" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.panes.find(ClientHarness.bootstrap_pane).?.input_modes.bracketed_paste = true;
    const configured = try fixtures.installTestingLuaBinding(&harness,
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

    try std.testing.expectEqual(keyinput.Control.continue_routing, try client_module.actions.executeAction(client, configured, .binding));
    try std.testing.expectEqualDeep(version, client.model.version());
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .pane_input);
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, message.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x1b[200~hello\x1b[201~", message.pane_input.bytes);

    _ = try client_module.actions.executeAction(client, .enter_copy_mode, .effect);
    const copy_version = client.model.version();
    const outbox_len = client.model.to_runtime.len;
    try std.testing.expectEqual(keyinput.Control.continue_routing, try client_module.actions.executeAction(client, configured, .binding));

    try std.testing.expect(data.copy_mode.isActive(&client.model));
    try std.testing.expectEqualDeep(copy_version, client.model.version());
    try std.testing.expectEqual(outbox_len, client.model.to_runtime.len);
}

test "Lua callback failure commits one diagnostic without direct presentation" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const configured = try fixtures.installTestingLuaBinding(&harness,
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
    try harness.settleModelPresentation();
    const version_before = client.model.version();
    const observed_before = client.presentation.observed;

    const control = try client_module.actions.executeAction(client, configured, .binding);

    try std.testing.expect(control == .continue_routing);
    try std.testing.expect(std.mem.indexOf(
        u8,
        data.client_diagnostic.shown(&client.model).?,
        "callback exploded",
    ) != null);
    var expected = version_before;
    expected.diagnostic += 1;
    try std.testing.expectEqualDeep(expected, client.model.version());
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);

    try harness.settleModelPresentation();
    try std.testing.expectEqual(expected.diagnostic, client.presentation.prepared.model.diagnostic);
}

test "attachment modal captures semantic keys until escape closes it" {
    var shelf: PreviewShelf = .{ .catalog = .init(std.testing.allocator) };
    defer shelf.catalog.deinit();
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.client.attachments = shelf.port();
    try harness.bootstrap();
    const client = harness.client;
    const target = try fixtures.installTestingAttachmentTarget(client, 1);
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
    _ = try client.attachments.?.adopt(capture);
    capture_owned = false;
    const snapshot = shelf.catalog.snapshot();
    try std.testing.expectEqual(@as(u8, 1), snapshot.len);
    try std.testing.expect(shelf.catalog.openModal(snapshot.items[0].id));
    const version = client.model.version();
    const observed_before = client.presentation.observed;

    try std.testing.expect(data.key_routing.captures(client_module.key_routing.keyRoutingAuthority(client)));
    _ = try client_module.key_routing.routeKeyInput(client, .{ .key = try keyinput.chord.parseKey("x") });

    try std.testing.expect(shelf.catalog.hasModal());
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);

    _ = try client_module.key_routing.routeKeyInput(client, .{ .key = try keyinput.chord.parseKey("escape") });

    try std.testing.expect(!shelf.catalog.hasModal());
    try std.testing.expect(!data.key_routing.captures(client_module.key_routing.keyRoutingAuthority(client)));
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "control-v reaches the pane when no clipboard preview target exists" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    _ = try client_module.key_routing.routeKeyInput(client, .{ .key = try keyinput.chord.parseKey("ctrl+v") });

    try std.testing.expect(client.model.clipboard.capture == null);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .pane_input);
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, message.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x16", message.pane_input.bytes);
}

test "clipboard image completion publishes resource ingress before presentation" {
    var shelf: PreviewShelf = .{ .catalog = .init(std.testing.allocator) };
    defer shelf.catalog.deinit();
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.client.attachments = shelf.port();
    try harness.bootstrap();
    const client = harness.client;
    const target = try fixtures.installTestingAttachmentTarget(client, 1);
    try harness.settleModelPresentation();
    const execution = (try client.model.clipboard.reserve(target)).?;
    const completed = try fixtures.testingClipboardCapture(client, execution, "png");
    const version_before = client.model.version();
    const observed_before = client.presentation.observed;

    try client_module.clipboard_capture.completeClipboardCapture(client, .{
        .execution_id = execution.id,
        .result = completed,
    });

    try std.testing.expect(client.model.clipboard.capture == null);
    try std.testing.expect(client.model.clipboard.orphan == null);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(@as(u64, 1), shelf.catalog.ingressVersion());
    try std.testing.expectEqual(@as(u8, 1), shelf.catalog.snapshot().len);
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);

    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);
}

test "clipboard image from a retired agent target is consumed and freed" {
    var shelf: PreviewShelf = .{ .catalog = .init(std.testing.allocator) };
    defer shelf.catalog.deinit();
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.client.attachments = shelf.port();
    try harness.bootstrap();
    const client = harness.client;
    const target = try fixtures.installTestingAttachmentTarget(client, 1);
    try harness.settleModelPresentation();
    const execution = (try client.model.clipboard.reserve(target)).?;
    const completed = try fixtures.testingClipboardCapture(client, execution, "private png");

    _ = try data.agent_snapshot.reconcile(&client.model, .{ .revision = 2, .agents = &.{} });
    _ = try client_module.pane_attachment.synchronizePaneAttachments(client);
    try harness.settleModelPresentation();
    const version_before = client.model.version();
    const observed_before = client.presentation.observed;

    try client_module.clipboard_capture.completeClipboardCapture(client, .{
        .execution_id = execution.id,
        .result = completed,
    });

    try std.testing.expect(client.model.clipboard.capture == null);
    try std.testing.expect(client.model.clipboard.orphan == null);
    try std.testing.expectEqual(@as(u64, 0), shelf.catalog.ingressVersion());
    try std.testing.expectEqual(@as(u8, 0), shelf.catalog.snapshot().len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);
}

test "clipboard image failures settle lifecycle without direct presentation" {
    var shelf: PreviewShelf = .{ .catalog = .init(std.testing.allocator) };
    defer shelf.catalog.deinit();
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.client.attachments = shelf.port();
    try harness.bootstrap();
    const client = harness.client;
    const target = try fixtures.installTestingAttachmentTarget(client, 1);
    try harness.settleModelPresentation();
    const observed_before = client.presentation.observed;
    const no_image = (try client.model.clipboard.reserve(target)).?;
    const version_before_empty = client.model.version();

    try client_module.clipboard_capture.completeClipboardCapture(client, .{
        .execution_id = no_image.id,
        .result = error.NoImageOnClipboard,
    });

    try std.testing.expect(client.model.clipboard.capture == null);
    try std.testing.expectEqualDeep(version_before_empty, client.model.version());
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);

    const too_large = (try client.model.clipboard.reserve(target)).?;
    const version_before_large = client.model.version();
    try client_module.clipboard_capture.completeClipboardCapture(client, .{
        .execution_id = too_large.id,
        .result = error.ClipboardImageTooLarge,
    });

    try std.testing.expect(client.model.clipboard.capture == null);
    try std.testing.expect(client.model.version().notifications > version_before_large.notifications);
    try std.testing.expect(client.model.notification_scheduler.pending);
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);

    const invalid = (try client.model.clipboard.reserve(target)).?;
    const completed = try fixtures.testingClipboardCapture(client, invalid, "invalid");
    completed.width = 0;
    const version_before_invalid = client.model.version();
    try client_module.clipboard_capture.completeClipboardCapture(client, .{
        .execution_id = invalid.id,
        .result = completed,
    });

    try std.testing.expect(client.model.clipboard.capture == null);
    try std.testing.expect(client.model.clipboard.orphan == null);
    try std.testing.expect(client.model.version().notifications > version_before_invalid.notifications);
    try std.testing.expectEqual(@as(u64, 0), shelf.catalog.ingressVersion());
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);
}

test "configuration watch rejects incomplete ownership before starting a worker" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.reload.force_next = true;
    try client_module.config_adoption.scheduleConfigReload(client);
    try std.testing.expect(client.reload.force_next);

    client.options.config_path = "/unused/config.lua";
    try std.testing.expectError(error.ConfigurationNotLoaded, client_module.config_adoption.scheduleConfigReload(client));
    client.options.trust_path = "/unused/trust.json";
    try std.testing.expectError(error.ConfigurationNotLoaded, client_module.config_adoption.scheduleConfigReload(client));
    client.options.config_path = null;
    _ = try fixtures.reloadConfiguration(&harness, try fixtures.testingConfigAdoption(1, false));
    client.options.config_path = "/unused/config.lua";
    const registry = client.plugin_registry;
    client.plugin_registry = null;
    defer client.plugin_registry = registry;
    try std.testing.expectError(error.ConfigurationNotLoaded, client_module.config_adoption.scheduleConfigReload(client));
    try std.testing.expect(client.reload.force_next);
}

test "bar configuration excludes Lua sources from a different model generation" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    try std.testing.expect(client_module.bar_updates.barConfiguration(client) == null);
    try client_module.bar_updates.synchronizeBars(client);
    try std.testing.expect(client.model.bar_updates.nextDeadline() == null);
    try std.testing.expect(!client.model.bar_updates.scheduler.pending);

    _ = try fixtures.reloadConfiguration(&harness, try fixtures.testingConfigAdoption(1, false));
    const generation = client.lua_generation.?;
    try std.testing.expect(client_module.bar_updates.barConfiguration(client) == &generation.snapshot.bars);
    const snapshot = &generation.snapshot;
    _ = try data.config_reload.apply(&client.model, 
        .{
            .generation = generation.number + 1,
            .sidebar_visible = snapshot.sidebar_visible,
            .pane_gaps = snapshot.pane_gaps,
            .window_title = snapshot.windowTitle(),
            .bars = snapshot.bars.presentation(),
        },
    );
    try std.testing.expect(client_module.bar_updates.barConfiguration(client) == null);
    client.model.bar_updates.pending_callbacks = data.bar_values.Position.bottom_left.bit();
    try client_module.bar_updates.synchronizeBars(client);
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
    var harness: ClientHarness = undefined;
    try harness.initWithOptions(.{
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

test "a bar component opens its Lua panel above the bar and escape closes it" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const adoption = try fixtures.testingConfigAdoptionSource(1,
        \\local telar = require("telar")
        \\local ui = telar.ui
        \\return { api_version = 2, client = {
        \\  panels = {
        \\    usage = telar.panel({ title = "Usage", render = function()
        \\      return { ui.heading("On track"), ui.meter_row({ label = "Session", value = 0.22, marker = 0.7 }) }
        \\    end }),
        \\  },
        \\  bars = { bottom = {
        \\    left = telar.bar.static({
        \\      ui.group({ mark = "claude", on_click = telar.action.open_panel("usage"), ui.meter({ label = "5h", value = 0.22 }) }),
        \\    }),
        \\    right = telar.bar.tabs(),
        \\  } },
        \\} }
    );
    _ = try fixtures.reloadConfiguration(&harness, adoption);
    try harness.settleModelPresentation();

    const component: data.BarComponent = .{ .position = .bottom_left, .node = 0 };
    _ = try client_module.view_interactions.apply(client, client.model.tabs.active, .{
        .intent = .{ .bar_component = component },
        .consumed = true,
    });
    try std.testing.expect(client.model.bars.panel.configured().? == 0);
    try std.testing.expectEqualDeep(component, client.model.bars.panel.anchor.?);
    switch (try harness.receiveClient()) {
        .bar_tick => |result| try client_module.bar_updates.handleTick(client, result),
        else => return error.UnexpectedEvent,
    }
    try std.testing.expectEqual(data.PanelStatus.ready, client.model.bars.panel.status);
    try std.testing.expectEqual(@as(u8, 2), client.model.bars.panel.content.node_count);

    const content = &client.model.bars.panel.content;
    try std.testing.expect(std.mem.indexOf(u8, content.text_bytes[0..content.text_len], "On track") != null);

    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);

    _ = try client_module.key_routing.routeKeyInput(client, .{ .key = .{ .code = .escape } });
    try std.testing.expect(!client.model.bars.panel.isOpen());
}


test "a reload that still sets retired keys adopts and warns which were ignored" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const source =
        \\return { api_version = 2, client = {
        \\  icons = "nerd-font",
        \\  sidebar = { renderer = "automatic" },
        \\} }
    ;

    _ = try fixtures.reloadConfiguration(&harness, try fixtures.testingConfigAdoptionSource(2, source));

    try std.testing.expectEqual(@as(u64, 2), client.model.configuration_generation);
    const center = &client.model.notification_center;
    try std.testing.expectEqual(@as(u8, 2), center.count);
    try std.testing.expectEqualStrings("Configuration reloaded", center.itemAt(1).?.title());
    const warning = center.itemAt(0).?;
    try std.testing.expectEqualStrings("Configuration keys ignored", warning.title());
    try std.testing.expectEqualStrings(
        "Ignored client.sidebar.renderer, client.icons: only the retired terminal client used them; remove them",
        warning.message(),
    );
}

test "a client started with retired keys adopts the file and warns once" {
    var diagnostic: data.Diagnostic = .{};
    const generation = try client_module.Generation.loadSource(
        .{
            .gpa = std.testing.allocator,
            .io = std.testing.io,
            .diagnostic = &diagnostic,
        },
        .{
            .source = "return { api_version = 2, client = { notifications = { delivery = 'terminal' }, input = { escape_timeout_ms = 25 } } }",
            .source_name = "@config.lua",
            .number = 1,
        },
    );
    var harness: ClientHarness = undefined;
    try harness.initWithOptions(.{
        .arguments = &.{},
        .cwd = "/",
        .endpoint = "",
        .lua_generation = generation,
    });
    defer harness.deinit();

    const client = harness.client;
    try std.testing.expectEqual(data.NotificationDelivery.telar, client.model.config.notification_delivery);
    try std.testing.expectEqual(@as(u8, 1), client.model.notification_center.count);
    try std.testing.expectEqualStrings(
        "Ignored client.notifications.delivery = \"terminal\", client.input.escape_timeout_ms: only the retired terminal client used them; remove them",
        client.model.notification_center.itemAt(0).?.message(),
    );
}
