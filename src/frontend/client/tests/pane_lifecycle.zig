//! Client integration tests for pane lifecycle.

const core = @import("telar-core");
const client_module = @import("telar-client");
const data = @import("model");
const TestHarness = @import("TestHarness.zig");
const std = @import("std");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const host_inputs = @import("../input/host_inputs.zig");
const term = @import("../../presentation/screen_support.zig");
const support = @import("support.zig");

test "pane focus commits before reports resize and presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const second: core.PaneId = @enumFromInt(20);
    const area = terminal.view.workbench();

    const split = try client.model.commitPaneSplit(.{
        .split = .{
            .target_pane = TestHarness.bootstrap_pane,
            .location = TestHarness.bootstrap_location,
            .axis = .horizontal,
            .area = area,
        },
        .new_pane = second,
    });
    try std.testing.expect(split.disposition == .active);
    const model = client.model.tabs.active;
    try std.testing.expect(client.model.tabs.layout[model].toggleFullscreen());
    client.model.panes.findIn(client.model.tabs.location[model].tab_id, TestHarness.bootstrap_pane).?.input_modes.focus_events = true;
    client.model.panes.findIn(client.model.tabs.location[model].tab_id, second).?.input_modes.focus_events = true;
    try presentation_lifecycle.observe(terminal);
    try harness.settleModelPresentation();

    _ = client.model.syncReportedPaneFocus().?;
    const version_before = client.model.version();
    const pending_updates_before = terminal.presenter.pending_updates;

    _ = try client_module.actions.executeAction(
        client,
        .{
            .focus_pane = .left,
        },
        .effect,
    );

    try std.testing.expectEqual(TestHarness.bootstrap_pane, client.model.tabs.layout[model].focused().?);
    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(version_before.workspace, client.model.version().workspace);
    try std.testing.expectEqual(version_before.tabs, client.model.version().tabs);
    try std.testing.expectEqual(version_before.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before, terminal.presenter.pending_updates);
    const expected_size = data.tab_layout.contentSize(&client.model, model, TestHarness.bootstrap_pane, area).?;

    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const focus_out = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(focus_out == .pane_input);
    try std.testing.expectEqual(second, focus_out.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x1b[O", focus_out.pane_input.bytes);
    const focus_in = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(focus_in == .pane_input);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, focus_in.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x1b[I", focus_in.pane_input.bytes);
    const resize = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(resize == .pane_resize);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, resize.pane_resize.pane_id);
    try std.testing.expectEqual(expected_size, resize.pane_resize.size);

    try presentation_lifecycle.observe(terminal);
    try std.testing.expectEqual(pending_updates_before + 1, terminal.presenter.pending_updates);
    try std.testing.expectEqualDeep(client.model.version(), terminal.presenter.presentation_state.observed.model);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), terminal.presenter.presentation_state.prepared.model);

    const version_before_noop = client.model.version();
    const pending_updates_before_noop = terminal.presenter.pending_updates;
    _ = try client_module.actions.executeAction(
        client,
        .{
            .focus_pane = .left,
        },
        .effect,
    );
    try presentation_lifecycle.observe(terminal);

    try std.testing.expectEqualDeep(version_before_noop, client.model.version());
    try std.testing.expectEqual(pending_updates_before_noop, terminal.presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "fullscreen tab round trip reconnects panes revealed by focus or tiled layout" {
    for ([_]bool{ false, true }) |exit_fullscreen| {
        var harness: TestHarness = undefined;
        try harness.init();
        defer harness.deinit();
        try harness.bootstrap();
        try harness.allowTabSelection();
        const client = harness.client;
        const terminal = harness.terminal;
        _ = try client.model.reconcileTab(.{
            .location = TestHarness.bootstrap_location,
            .panes = &.{TestHarness.bootstrap_pane},
        }, terminal.view.workbench());
        const sibling: core.PaneId = @enumFromInt(20);
        const other_tab_pane: core.PaneId = @enumFromInt(30);
        const model = client.model.tabs.active;
        try data.pane_split.split(&client.model, model, .{
            .existing_pane = TestHarness.bootstrap_pane,
            .new_pane = sibling,
            .location = TestHarness.bootstrap_location,
            .axis = .horizontal,
            .area = terminal.view.workbench(),
        });
        try std.testing.expect(client.model.tabs.layout[model].toggleFullscreen());
        _ = try harness.addInactiveTab(@enumFromInt(2), other_tab_pane);
        const scenario: FullscreenReattachment = .{ .harness = &harness };
        const original_panes = [_]core.PaneDescriptor{
            .{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running },
            .{ .pane_id = sibling, .lifecycle = .running },
        };

        try scenario.selectTab(1, &.{.{ .pane_id = other_tab_pane, .lifecycle = .running }});
        try scenario.selectTab(0, &original_panes);
        try std.testing.expect(client.model.tabs.layout[model].isFullscreen());
        try std.testing.expect(!client.model.panes.findIn(client.model.tabs.location[model].tab_id, TestHarness.bootstrap_pane).?.attached);
        try scenario.expectInput(sibling);

        if (exit_fullscreen) {
            _ = try client_module.actions.executeAction(client, .toggle_pane_fullscreen, .effect);
            try harness.settle();
            var buffer: [256]u8 = undefined;
            const resize = try harness.nextClientMessage(&buffer);
            try std.testing.expect(resize == .pane_resize);
            try std.testing.expectEqual(sibling, resize.pane_resize.pane_id);
        } else {
            _ = try client_module.actions.executeAction(
                client,
                .{
                    .focus_pane = .left,
                },
                .effect,
            );
            _ = try client_module.actions.executeAction(
                client,
                .{
                    .focus_pane = .right,
                },
                .effect,
            );
            _ = try client_module.actions.executeAction(
                client,
                .{
                    .focus_pane = .left,
                },
                .effect,
            );
        }

        try scenario.confirmAttachment(TestHarness.bootstrap_pane);
        if (exit_fullscreen) {
            _ = try client_module.actions.executeAction(
                client,
                .{
                    .focus_pane = .left,
                },
                .effect,
            );
        } else {
            // Returning to the attached sibling resized it, but did not duplicate the pending open.
            var buffer: [256]u8 = undefined;
            const resize = try harness.nextClientMessage(&buffer);
            try std.testing.expect(resize == .pane_resize);
            try std.testing.expectEqual(sibling, resize.pane_resize.pane_id);
        }

        try scenario.expectInput(TestHarness.bootstrap_pane);
        _ = try client_module.actions.executeAction(
            client,
            .{
                .focus_pane = .right,
            },
            .effect,
        );
        if (!exit_fullscreen) {
            try harness.settle();
            var buffer: [256]u8 = undefined;
            try std.testing.expect((try harness.nextClientMessage(&buffer)) == .pane_resize);
        }

        try scenario.expectInput(sibling);
        try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
    }
}

test "navigation forwards the canonical key only to Neovim at a Telar edge" {
    for ([_][]const u8{ "nvim", "zsh" }) |foreground_name| {
        var harness: TestHarness = undefined;
        try harness.init();
        defer harness.deinit();
        try harness.bootstrap();

        var payload: [128]u8 = undefined;
        const foreground = try core.encodePaneForeground(&payload, .{
            .pane_id = TestHarness.bootstrap_pane,
            .name = foreground_name,
        });
        _ = try client_module.runtime_messages.handleServerMessage(harness.client, try core.decodeServer(foreground));

        if (!std.mem.eql(u8, foreground_name, "nvim")) {
            const version = harness.client.model.version();
            for (std.enums.values(data.InputDirection)) |direction| {
                _ = try client_module.actions.executeAction(
                    harness.client,
                    .{
                        .navigate_pane = direction,
                    },
                    .effect,
                );
                try std.testing.expectEqualDeep(version, harness.client.model.version());
                try std.testing.expectEqual(@as(usize, 0), harness.client.model.to_runtime.len);
            }

            continue;
        }

        _ = try client_module.actions.executeAction(
            harness.client,
            .{
                .navigate_pane = .left,
            },
            .effect,
        );
        try harness.settle();

        var message_buffer: [256]u8 = undefined;
        const message = try harness.nextClientMessage(&message_buffer);
        try std.testing.expect(message == .pane_input);
        try std.testing.expectEqual(TestHarness.bootstrap_pane, message.pane_input.pane_id);
        try std.testing.expectEqualStrings("\x08", message.pane_input.bytes);
    }
}

test "runtime focus command reports a directionless client layout" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();

    var payload: [128]u8 = undefined;
    const command = try core.encodePaneFocusCommand(&payload, .{
        .requester = .{ .id = 8, .generation = 9 },
        .request_id = @enumFromInt(3),
        .pane_id = TestHarness.bootstrap_pane,
        .pane_generation = 4,
        .direction = .left,
    });
    _ = try client_module.runtime_messages.handleServerMessage(harness.client, try core.decodeServer(command));
    try harness.settle();

    var message_buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(message == .complete_pane_focus);
    try std.testing.expectEqual(core.PaneFocusOutcome.no_neighbor, message.complete_pane_focus.outcome);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, message.complete_pane_focus.focused_pane_id);
}

test "navigation lets Neovim consume internal movement before Telar focus" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const second: core.PaneId = @enumFromInt(20);
    _ = try client.model.commitPaneSplit(.{
        .split = .{
            .target_pane = TestHarness.bootstrap_pane,
            .location = TestHarness.bootstrap_location,
            .axis = .horizontal,
            .area = terminal.view.workbench(),
        },
        .new_pane = second,
    });

    var payload: [128]u8 = undefined;
    const nvim = try core.encodePaneForeground(&payload, .{ .pane_id = second, .name = "nvim" });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(nvim));
    _ = try client_module.actions.executeAction(
        client,
        .{
            .navigate_pane = .left,
        },
        .effect,
    );
    try std.testing.expectEqual(second, client.model.tabs.layout[client.model.tabs.active].focused().?);
    try harness.settle();

    var message_buffer: [256]u8 = undefined;
    const forwarded = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(forwarded == .pane_input);
    try std.testing.expectEqual(second, forwarded.pane_input.pane_id);

    const shell = try core.encodePaneForeground(&payload, .{ .pane_id = second, .name = "zsh" });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(shell));
    _ = try client_module.actions.executeAction(
        client,
        .{
            .navigate_pane = .left,
        },
        .effect,
    );
    try std.testing.expectEqual(TestHarness.bootstrap_pane, client.model.tabs.layout[client.model.tabs.active].focused().?);
}

test "mouse focus precedes forwarding its triggering press" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const first = TestHarness.bootstrap_pane;
    const second: core.PaneId = @enumFromInt(20);
    const area = terminal.view.workbench();

    _ = try client.model.commitPaneSplit(.{
        .split = .{
            .target_pane = first,
            .location = TestHarness.bootstrap_location,
            .axis = .horizontal,
            .area = area,
        },
        .new_pane = second,
    });
    const model = client.model.tabs.active;
    client.model.panes.findIn(client.model.tabs.location[model].tab_id, first).?.input_modes.focus_events = true;
    client.model.panes.findIn(client.model.tabs.location[model].tab_id, first).?.mouse = .{ .tracking = .normal, .sgr = true };
    client.model.panes.findIn(client.model.tabs.location[model].tab_id, second).?.input_modes.focus_events = true;
    try presentation_lifecycle.observe(terminal);
    try harness.settleModelPresentation();

    _ = client.model.syncReportedPaneFocus().?;
    const first_view = data.tab_layout.view(&client.model, model, first, area).?;
    const point = term.Event.Mouse{
        .x = first_view.content.x,
        .y = first_view.content.y,
        .kind = .move,
    };
    try host_inputs.mouse(terminal, point);
    const version_before = client.model.version();
    var press = point;
    press.kind = .press;

    try host_inputs.mouse(terminal, press);

    try std.testing.expectEqual(first, client.model.tabs.layout[model].focused().?);
    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
    try harness.settle();

    var message_buffer: [256]u8 = undefined;
    const focus_out = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(focus_out == .pane_input);
    try std.testing.expectEqual(second, focus_out.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x1b[O", focus_out.pane_input.bytes);
    const focused_input = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(focused_input == .pane_input);
    try std.testing.expectEqual(first, focused_input.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x1b[I\x1b[<0;1;1M", focused_input.pane_input.bytes);
}

test "pane geometry delivery offers only attached visible panes" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const area = terminal.view.workbench();
    const active = client.model.tabs.active;
    const expected_size = data.tab_layout.contentSize(&client.model, active, TestHarness.bootstrap_pane, area).?;

    try client_module.pane_resize.resizeAttachedPanes(client, active, area);
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const offered = try harness.nextClientMessage(&buffer);
    try std.testing.expect(offered == .pane_resize);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, offered.pane_resize.pane_id);
    try std.testing.expectEqual(expected_size, offered.pane_resize.size);

    const detached_location = try harness.addInactiveTab(@enumFromInt(2), @enumFromInt(20));
    const detached = client.model.tabs.find(detached_location.tab_id).?;
    try client_module.pane_resize.resizeAttachedPanes(client, detached, area);

    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
    try std.testing.expect(!client.model.to_runtime.inFlight());
}

test "pane resize publishes committed geometry before presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const first = TestHarness.bootstrap_pane;
    const second: core.PaneId = @enumFromInt(20);
    const area = terminal.view.workbench();

    _ = try client.model.commitPaneSplit(.{
        .split = .{
            .target_pane = first,
            .location = TestHarness.bootstrap_location,
            .axis = .horizontal,
            .area = area,
        },
        .new_pane = second,
    });
    try presentation_lifecycle.observe(terminal);
    try harness.settleModelPresentation();
    const model = client.model.tabs.active;
    const first_before = data.tab_layout.contentSize(&client.model, model, first, area).?;
    const second_before = data.tab_layout.contentSize(&client.model, model, second, area).?;
    const version_before = client.model.version();
    const pending_updates_before = terminal.presenter.pending_updates;

    _ = try client_module.actions.executeAction(
        client,
        .{
            .resize_pane = .left,
        },
        .effect,
    );

    const first_after = data.tab_layout.contentSize(&client.model, model, first, area).?;
    const second_after = data.tab_layout.contentSize(&client.model, model, second, area).?;
    try std.testing.expect(first_after.cols < first_before.cols);
    try std.testing.expect(second_after.cols > second_before.cols);
    try std.testing.expectEqual(second, client.model.tabs.layout[model].focused().?);
    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(version_before.workspace, client.model.version().workspace);
    try std.testing.expectEqual(version_before.tabs, client.model.version().tabs);
    try std.testing.expectEqual(version_before.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before, terminal.presenter.pending_updates);
    try std.testing.expect(!terminal.view.dirty);

    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const first_resize = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(first_resize == .pane_resize);
    try std.testing.expectEqual(first, first_resize.pane_resize.pane_id);
    try std.testing.expectEqual(first_after, first_resize.pane_resize.size);
    const second_resize = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(second_resize == .pane_resize);
    try std.testing.expectEqual(second, second_resize.pane_resize.pane_id);
    try std.testing.expectEqual(second_after, second_resize.pane_resize.size);

    try presentation_lifecycle.observe(terminal);
    try std.testing.expectEqual(pending_updates_before + 1, terminal.presenter.pending_updates);
    try std.testing.expectEqualDeep(client.model.version(), terminal.presenter.presentation_state.observed.model);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), terminal.presenter.presentation_state.prepared.model);

    const version_before_noop = client.model.version();
    const pending_updates_before_noop = terminal.presenter.pending_updates;
    _ = try client_module.actions.executeAction(
        client,
        .{
            .resize_pane = .up,
        },
        .effect,
    );
    try presentation_lifecycle.observe(terminal);

    try std.testing.expectEqualDeep(version_before_noop, client.model.version());
    try std.testing.expectEqual(pending_updates_before_noop, terminal.presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
    try std.testing.expect(!terminal.view.dirty);
}

test "single-pane fullscreen publishes bordered and restored geometry" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const pane_id = TestHarness.bootstrap_pane;
    const area = terminal.view.workbench();
    const model = client.model.tabs.active;
    const initial = data.tab_layout.contentSize(&client.model, model, pane_id, area).?;
    var message_buffer: [256]u8 = undefined;

    for ([_]bool{ true, false }) |fullscreen| {
        const version = client.model.version();
        const pending_updates = terminal.presenter.pending_updates;
        _ = try client_module.actions.executeAction(client, .toggle_pane_fullscreen, .effect);
        const expected = if (fullscreen)
            core.TerminalSize{ .cols = area.w - 2, .rows = area.h - 2 }
        else
            initial;
        try std.testing.expectEqual(fullscreen, client.model.tabs.layout[model].isFullscreen());
        try std.testing.expectEqual(expected, data.tab_layout.contentSize(&client.model, model, pane_id, area).?);
        try std.testing.expectEqual(version.panes + 1, client.model.version().panes);
        try std.testing.expectEqual(pending_updates, terminal.presenter.pending_updates);
        try harness.settle();
        const message = try harness.nextClientMessage(&message_buffer);
        try std.testing.expect(message == .pane_resize);
        try std.testing.expectEqual(pane_id, message.pane_resize.pane_id);
        try std.testing.expectEqual(expected, message.pane_resize.size);
        try presentation_lifecycle.observe(terminal);
        try harness.settleModelPresentation();
        try std.testing.expectEqualDeep(client.model.version(), terminal.presenter.presentation_state.prepared.model);
    }
}

test "pane fullscreen publishes visible geometry without direct presentation scheduling" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const first = TestHarness.bootstrap_pane;
    const second: core.PaneId = @enumFromInt(20);
    const area = terminal.view.workbench();

    _ = try client.model.commitPaneSplit(.{
        .split = .{
            .target_pane = first,
            .location = TestHarness.bootstrap_location,
            .axis = .horizontal,
            .area = area,
        },
        .new_pane = second,
    });
    try presentation_lifecycle.observe(terminal);
    try harness.settleModelPresentation();
    const model = client.model.tabs.active;
    const first_tiled = data.tab_layout.contentSize(&client.model, model, first, area).?;
    const second_tiled = data.tab_layout.contentSize(&client.model, model, second, area).?;
    const version_before_enter = client.model.version();
    const pending_updates_before_enter = terminal.presenter.pending_updates;

    _ = try client_module.actions.executeAction(client, .toggle_pane_fullscreen, .effect);

    try std.testing.expect(client.model.tabs.layout[model].isFullscreen());
    try std.testing.expect(data.tab_layout.contentSize(&client.model, model, first, area) == null);
    const fullscreen_size = data.tab_layout.contentSize(&client.model, model, second, area).?;
    try std.testing.expectEqual(core.TerminalSize{ .cols = area.w - 2, .rows = area.h - 2 }, fullscreen_size);
    try std.testing.expectEqual(version_before_enter.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_enter, terminal.presenter.pending_updates);
    try std.testing.expect(!terminal.view.dirty);

    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const fullscreen_resize = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(fullscreen_resize == .pane_resize);
    try std.testing.expectEqual(second, fullscreen_resize.pane_resize.pane_id);
    try std.testing.expectEqual(fullscreen_size, fullscreen_resize.pane_resize.size);

    try presentation_lifecycle.observe(terminal);
    try std.testing.expectEqual(pending_updates_before_enter + 1, terminal.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), terminal.presenter.presentation_state.prepared.model);

    const version_before_exit = client.model.version();
    const pending_updates_before_exit = terminal.presenter.pending_updates;
    _ = try client_module.actions.executeAction(client, .toggle_pane_fullscreen, .effect);

    try std.testing.expect(!client.model.tabs.layout[model].isFullscreen());
    try std.testing.expectEqual(first_tiled, data.tab_layout.contentSize(&client.model, model, first, area).?);
    try std.testing.expectEqual(second_tiled, data.tab_layout.contentSize(&client.model, model, second, area).?);
    try std.testing.expectEqual(version_before_exit.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_exit, terminal.presenter.pending_updates);
    try std.testing.expect(!terminal.view.dirty);

    try harness.settle();
    const first_resize = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(first_resize == .pane_resize);
    try std.testing.expectEqual(first, first_resize.pane_resize.pane_id);
    try std.testing.expectEqual(first_tiled, first_resize.pane_resize.size);
    const second_resize = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(second_resize == .pane_resize);
    try std.testing.expectEqual(second, second_resize.pane_resize.pane_id);
    try std.testing.expectEqual(second_tiled, second_resize.pane_resize.size);

    try presentation_lifecycle.observe(terminal);
    try std.testing.expectEqual(pending_updates_before_exit + 1, terminal.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), terminal.presenter.presentation_state.prepared.model);
}

test "sidebar toggle commits chrome before geometry and presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const shown_area = terminal.view.workbench();
    const version_before_hide = client.model.version();
    const pending_updates_before_hide = terminal.presenter.pending_updates;

    _ = try client_module.actions.executeAction(client, .toggle_sidebar, .effect);
    try harness.deliverHostEffects();

    const hidden_area = terminal.view.workbench();
    try std.testing.expect(hidden_area.w > shown_area.w);
    try std.testing.expect(!client.model.sidebar_visible);
    try std.testing.expect(!terminal.view.sidebar_requested);
    try std.testing.expectEqual(version_before_hide.chrome + 1, client.model.version().chrome);
    try std.testing.expectEqual(version_before_hide.workspace, client.model.version().workspace);
    try std.testing.expectEqual(version_before_hide.tabs, client.model.version().tabs);
    try std.testing.expectEqual(version_before_hide.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(version_before_hide.panes, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_hide, terminal.presenter.pending_updates);
    try std.testing.expect(terminal.view.dirty);

    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const expanded = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(expanded == .pane_resize);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, expanded.pane_resize.pane_id);
    try std.testing.expectEqual(
        core.TerminalSize{ .cols = hidden_area.w, .rows = hidden_area.h },
        expanded.pane_resize.size,
    );

    try presentation_lifecycle.observe(terminal);

    try std.testing.expectEqual(pending_updates_before_hide + 1, terminal.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), terminal.presenter.presentation_state.prepared.model);
    try std.testing.expect(!terminal.view.dirty);

    const version_before_show = client.model.version();
    const pending_updates_before_show = terminal.presenter.pending_updates;
    _ = try client_module.actions.executeAction(client, .toggle_sidebar, .effect);
    try harness.deliverHostEffects();

    try std.testing.expect(client.model.sidebar_visible);
    try std.testing.expect(terminal.view.sidebar_requested);
    try std.testing.expectEqualDeep(shown_area, terminal.view.workbench());
    try std.testing.expectEqual(version_before_show.chrome + 1, client.model.version().chrome);
    try std.testing.expectEqual(pending_updates_before_show, terminal.presenter.pending_updates);

    try harness.settle();
    const contracted = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(contracted == .pane_resize);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, contracted.pane_resize.pane_id);
    try std.testing.expectEqual(
        core.TerminalSize{ .cols = shown_area.w, .rows = shown_area.h },
        contracted.pane_resize.size,
    );

    try presentation_lifecycle.observe(terminal);

    try std.testing.expectEqual(pending_updates_before_show + 1, terminal.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), terminal.presenter.presentation_state.prepared.model);
}

test "sidebar resize keybinding commits width before pane geometry" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const version = client.model.version();

    _ = try client_module.actions.executeAction(
        client,
        .{
            .resize_sidebar = .right,
        },
        .effect,
    );
    try harness.deliverHostEffects();

    try std.testing.expectEqual(@as(u16, 44), client.model.sidebar_width);
    try std.testing.expectEqual(@as(u16, 44), terminal.view.regions.sidebar.w);
    try std.testing.expectEqual(version.chrome + 1, client.model.version().chrome);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const resized = try harness.nextClientMessage(&buffer);
    try std.testing.expect(resized == .pane_resize);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, resized.pane_resize.pane_id);
    try std.testing.expectEqual(
        core.TerminalSize{ .cols = 36, .rows = 22 },
        resized.pane_resize.size,
    );
}

test "sidebar toggle delivers the committed geometry to host resources" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const terminal = harness.terminal;
    terminal.view.dirty = false;
    terminal.graphics_store.damage = false;
    const shown_area = terminal.view.workbench();

    _ = try client_module.actions.executeAction(client, .toggle_sidebar, .effect);
    try harness.deliverHostEffects();

    try std.testing.expect(!client.model.sidebar_visible);
    try std.testing.expect(!terminal.view.sidebar_requested);
    try std.testing.expect(terminal.view.workbench().w > shown_area.w);
    try std.testing.expect(terminal.view.dirty);
    try std.testing.expect(terminal.graphics_store.damage);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "workspace list toggle is projected only by the presenter" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const version_before_collapse = client.model.version();
    const pending_updates_before_collapse = terminal.presenter.pending_updates;

    _ = try client_module.actions.executeAction(client, .toggle_workspace_list, .effect);

    try std.testing.expect(client.model.workspace_list_collapsed);
    try std.testing.expect(!terminal.view.workspace_list_collapsed);
    try std.testing.expectEqual(version_before_collapse.chrome + 1, client.model.version().chrome);
    try std.testing.expectEqual(version_before_collapse.workspace, client.model.version().workspace);
    try std.testing.expectEqual(version_before_collapse.tabs, client.model.version().tabs);
    try std.testing.expectEqual(version_before_collapse.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(version_before_collapse.panes, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_collapse, terminal.presenter.pending_updates);
    try std.testing.expect(!terminal.view.dirty);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);

    try presentation_lifecycle.observe(terminal);

    try std.testing.expectEqual(pending_updates_before_collapse + 1, terminal.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expect(terminal.view.workspace_list_collapsed);
    try std.testing.expectEqualDeep(client.model.version(), terminal.presenter.presentation_state.prepared.model);

    const version_before_expand = client.model.version();
    const pending_updates_before_expand = terminal.presenter.pending_updates;
    _ = try client_module.actions.executeAction(client, .toggle_workspace_list, .effect);

    try std.testing.expect(!client.model.workspace_list_collapsed);
    try std.testing.expect(terminal.view.workspace_list_collapsed);
    try std.testing.expectEqual(version_before_expand.chrome + 1, client.model.version().chrome);
    try std.testing.expectEqual(pending_updates_before_expand, terminal.presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);

    try presentation_lifecycle.observe(terminal);

    try std.testing.expectEqual(pending_updates_before_expand + 1, terminal.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expect(!terminal.view.workspace_list_collapsed);
    try std.testing.expectEqualDeep(client.model.version(), terminal.presenter.presentation_state.prepared.model);
}

test "an active split commits once and presentation observes the model" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;

    const split_pane: core.PaneId = @enumFromInt(21);
    try client.model.request_lifecycle.tracker.add(@enumFromInt(4), .{ .split = .{
        .target_pane = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .axis = .horizontal,
        .area = terminal.view.workbench(),
    } });
    const version_before = client.model.version();
    const pending_updates_before = terminal.presenter.pending_updates;
    var payload: [128]u8 = undefined;
    const opened = try core.encodePaneOpened(&payload, .{
        .request_id = @enumFromInt(4),
        .pane_id = split_pane,
        .location = TestHarness.bootstrap_location,
        .created = true,
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(opened));

    const pane = client.model.panes.find(split_pane).?;
    try std.testing.expect(pane.attached);
    try std.testing.expectEqual(split_pane, client.model.tabs.layout[client.model.tabs.active].focused().?);
    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before, terminal.presenter.pending_updates);

    try presentation_lifecycle.observe(terminal);

    try std.testing.expectEqual(pending_updates_before + 1, terminal.presenter.pending_updates);
}

test "an inactive split is retained detached without a visible revision" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const first = client.model.tabs.active;
    const second_location = try harness.addTab(@enumFromInt(2), @enumFromInt(20));
    var first_panes = client.model.panes.iterate(client.model.tabs.location[first].tab_id);
    while (first_panes.next()) |pane| {
        pane.attached = false;
        pane.pending_frame_id = 0;
    }
    try std.testing.expectEqualDeep(second_location, client.model.activeTabLocation().?);

    const split_pane: core.PaneId = @enumFromInt(21);
    try client.model.request_lifecycle.tracker.add(@enumFromInt(4), .{ .split = .{
        .target_pane = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .axis = .horizontal,
        .area = terminal.view.workbench(),
    } });
    const version_before = client.model.version();
    const pending_updates_before = terminal.presenter.pending_updates;
    var payload: [128]u8 = undefined;
    const opened = try core.encodePaneOpened(&payload, .{
        .request_id = @enumFromInt(4),
        .pane_id = split_pane,
        .location = TestHarness.bootstrap_location,
        .created = true,
    });

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(opened));

    try std.testing.expect(!client.model.panes.find(split_pane).?.attached);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, terminal.presenter.pending_updates);
    try std.testing.expect(!terminal.graphics_store.paneVisible(split_pane));
    try harness.settle();
    var message_buffer: [128]u8 = undefined;
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(split_pane, detached.detach_pane.pane_id);
}

test "a split reply for a retired tab detaches and refreshes canonical state" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    _ = client.model.request_lifecycle.tracker.take(@enumFromInt(2)) orelse return error.MissingWorkspaceSnapshot;
    _ = try harness.addTab(@enumFromInt(2), @enumFromInt(20));

    const split_pane: core.PaneId = @enumFromInt(21);
    try client.model.request_lifecycle.tracker.add(@enumFromInt(4), .{ .split = .{
        .target_pane = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .axis = .horizontal,
        .area = terminal.view.workbench(),
    } });
    client.model.request_lifecycle.tracker.ignoreTab(TestHarness.bootstrap_location.tab_id);
    try std.testing.expect(data.tab_removal.remove(&client.model, TestHarness.bootstrap_location.tab_id));
    const version_before = client.model.version();
    const pending_updates_before = terminal.presenter.pending_updates;
    var payload: [128]u8 = undefined;
    const opened = try core.encodePaneOpened(&payload, .{
        .request_id = @enumFromInt(4),
        .pane_id = split_pane,
        .location = TestHarness.bootstrap_location,
        .created = true,
    });

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(opened));

    try std.testing.expect(client.model.panes.find(split_pane) == null);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, terminal.presenter.pending_updates);
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(split_pane, detached.detach_pane.pane_id);
    const refresh = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(refresh == .request_workspace_snapshot);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location.workspace, refresh.request_workspace_snapshot.workspace);
}

test "a split reply replaces its target after canonical retirement" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;

    const split_pane: core.PaneId = @enumFromInt(21);
    try client.model.request_lifecycle.tracker.add(@enumFromInt(4), .{ .split = .{
        .target_pane = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .axis = .horizontal,
        .area = terminal.view.workbench(),
    } });
    try std.testing.expect(data.tab_layout.removePane(&client.model, TestHarness.bootstrap_pane));
    client.model.request_lifecycle.tracker.ignorePane(TestHarness.bootstrap_pane);
    const version_before = client.model.version();
    var payload: [128]u8 = undefined;
    const opened = try core.encodePaneOpened(&payload, .{
        .request_id = @enumFromInt(4),
        .pane_id = split_pane,
        .location = TestHarness.bootstrap_location,
        .created = true,
    });

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(opened));

    try std.testing.expect(client.model.panes.find(TestHarness.bootstrap_pane) == null);
    try std.testing.expect(client.model.panes.find(split_pane).?.attached);
    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
}

test "a failed split never resizes the tab selected afterwards" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const first = client.model.tabs.active;
    _ = try harness.addTab(@enumFromInt(2), @enumFromInt(20));
    var first_panes = client.model.panes.iterate(client.model.tabs.location[first].tab_id);
    while (first_panes.next()) |pane| {
        pane.attached = false;
        pane.pending_frame_id = 0;
    }

    try client.model.request_lifecycle.tracker.add(@enumFromInt(4), .{ .split = .{
        .target_pane = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .axis = .horizontal,
        .area = terminal.view.workbench(),
    } });
    const version_before = client.model.version();
    var payload: [128]u8 = undefined;
    const failed = try core.encodeRequestFailed(&payload, .{
        .request_id = @enumFromInt(4),
        .code = .internal,
        .message = "launch failed",
    });

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(failed));

    try std.testing.expectEqual(@as(u8, 0), client.model.to_runtime.len);
    try support.expectOnlyNotificationVersionChanged(version_before, client.model.version());
}

test "a failed split for a retired target is silent" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;

    try client.model.request_lifecycle.tracker.add(@enumFromInt(4), .{ .split = .{
        .target_pane = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .axis = .horizontal,
        .area = terminal.view.workbench(),
    } });
    try std.testing.expect(data.tab_layout.removePane(&client.model, TestHarness.bootstrap_pane));
    client.model.request_lifecycle.tracker.ignorePane(TestHarness.bootstrap_pane);
    const pending_updates_before = terminal.presenter.pending_updates;
    var payload: [128]u8 = undefined;
    const failed = try core.encodeRequestFailed(&payload, .{
        .request_id = @enumFromInt(4),
        .code = .pane_not_found,
        .message = "target exited",
    });

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(failed));

    try std.testing.expectEqual(@as(u8, 0), client.model.to_runtime.len);
    try std.testing.expectEqual(pending_updates_before, terminal.presenter.pending_updates);
}

test "an attach reply marks the discovered pane attached" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;

    const discovered: core.PaneId = @enumFromInt(11);
    var payload: [256]u8 = undefined;
    const attachment_request = try harness.discoverAndRequestAttachment(discovered, &payload);
    try std.testing.expect(!client.model.panes.find(discovered).?.attached);

    const version_before_confirmation = client.model.version();
    const pending_updates_before_confirmation = terminal.presenter.pending_updates;

    const opened = try core.encodePaneOpened(&payload, .{
        .request_id = attachment_request,
        .pane_id = discovered,
        .location = TestHarness.bootstrap_location,
        .created = false,
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(opened));

    try std.testing.expect(client.model.panes.find(discovered).?.attached);
    try std.testing.expectEqualDeep(version_before_confirmation, client.model.version());
    try std.testing.expectEqual(pending_updates_before_confirmation, terminal.presenter.pending_updates);
}

test "tab detachment retires an in-flight pane attachment" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;

    const discovered: core.PaneId = @enumFromInt(11);
    var payload: [256]u8 = undefined;
    const attachment_request = try harness.discoverAndRequestAttachment(discovered, &payload);
    try client_module.tab_removal.detachTab(client, client.model.tabs.location[client.model.tabs.active]);
    try harness.settle();

    var message_buffer: [256]u8 = undefined;
    var detached_root = false;
    var detached_discovered = false;
    for (0..2) |_| {
        const message = try harness.nextClientMessage(&message_buffer);
        try std.testing.expect(message == .detach_pane);
        if (message.detach_pane.pane_id == TestHarness.bootstrap_pane) {
            detached_root = true;
        } else if (message.detach_pane.pane_id == discovered) {
            detached_discovered = true;
        } else {
            return error.UnexpectedDetachedPane;
        }
    }
    try std.testing.expect(detached_root);
    try std.testing.expect(detached_discovered);
    try std.testing.expect(!client.model.request_lifecycle.tracker.hasPane(.attachment, discovered));

    const pending_updates_before_confirmation = terminal.presenter.pending_updates;
    const opened = try core.encodePaneOpened(&payload, .{
        .request_id = attachment_request,
        .pane_id = discovered,
        .location = TestHarness.bootstrap_location,
        .created = false,
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(opened));

    try std.testing.expect(!client.model.panes.find(discovered).?.attached);
    try std.testing.expectEqual(pending_updates_before_confirmation, terminal.presenter.pending_updates);
}

test "tab detachment closes a captured bracketed paste before the pane detaches" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.panes.find(TestHarness.bootstrap_pane).?.input_modes.bracketed_paste = true;

    _ = try client_module.paste_routing.start(client);
    try harness.settle();

    var message_buffer: [256]u8 = undefined;
    const opening = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(opening == .pane_input);
    try std.testing.expectEqualStrings("\x1b[200~", opening.pane_input.bytes);

    try client_module.tab_removal.detachTab(client, client.model.tabs.location[client.model.tabs.active]);

    try std.testing.expect(!client.model.panePasteActive());
    try harness.settle();
    const closing = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(closing == .pane_input);
    try std.testing.expectEqualStrings("\x1b[201~", closing.pane_input.bytes);
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, detached.detach_pane.pane_id);
}

test "tab detachment sends focus-out before the pane detaches" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.panes.find(TestHarness.bootstrap_pane).?.input_modes.focus_events = true;

    try client_module.pane_focus.synchronizeActivePane(client);
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const focus_in = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(focus_in == .pane_input);
    try std.testing.expectEqualStrings("\x1b[I", focus_in.pane_input.bytes);

    try client_module.tab_removal.detachTab(client, client.model.tabs.location[client.model.tabs.active]);

    try std.testing.expect(client.model.reported_pane_focus == null);
    try harness.settle();
    const focus_out = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(focus_out == .pane_input);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, focus_out.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x1b[O", focus_out.pane_input.bytes);
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, detached.detach_pane.pane_id);
}

test "tab detachment preserves focus reported by another tab" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.panes.find(TestHarness.bootstrap_pane).?.input_modes.focus_events = true;
    try client_module.pane_focus.synchronizeActivePane(client);
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const focus_in = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(focus_in == .pane_input);
    try std.testing.expectEqualStrings("\x1b[I", focus_in.pane_input.bytes);

    const inactive_pane: core.PaneId = @enumFromInt(20);
    const inactive = try harness.addInactiveTab(@enumFromInt(2), inactive_pane);
    const tab = client.model.tabs.find(inactive.tab_id).?;
    client.model.panes.findIn(client.model.tabs.location[tab].tab_id, inactive_pane).?.attached = true;
    const reported = client.model.reported_pane_focus.?;

    try client_module.tab_removal.detachTab(client, client.model.tabs.location[tab]);

    try std.testing.expectEqualDeep(reported, client.model.reported_pane_focus.?);
    try harness.settle();
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(inactive_pane, detached.detach_pane.pane_id);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "detach action releases every tab before stopping the client" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const second_pane: core.PaneId = @enumFromInt(20);
    _ = try harness.addTab(@enumFromInt(2), second_pane);
    const version = client.model.version();
    const pending_updates = terminal.presenter.pending_updates;

    try std.testing.expectEqual(
        data.KeybindControl.stop,
        try client_module.actions.executeAction(client, .detach, .effect),
    );

    try std.testing.expect(!client.model.panes.find(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expect(!client.model.panes.find(second_pane).?.attached);
    try std.testing.expect(!terminal.graphics_store.paneVisible(TestHarness.bootstrap_pane));
    try std.testing.expect(!terminal.graphics_store.paneVisible(second_pane));
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(pending_updates, terminal.presenter.pending_updates);

    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const first = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(first == .detach_pane);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, first.detach_pane.pane_id);
    const second = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(second == .detach_pane);
    try std.testing.expectEqual(second_pane, second.detach_pane.pane_id);
}

test "detach action captures layout changes from the same input batch" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const active = client.model.tabs.active;
    client.model.tabs.snapshot_loaded[active] = true;
    try client.model.client_layouts.markSnapshotReceived();

    _ = try client_module.actions.executeAction(
        client,
        .{
            .resize_sidebar = .right,
        },
        .effect,
    );
    try std.testing.expectEqual(data.KeybindControl.stop, try client_module.actions.executeAction(client, .detach, .effect));
    try harness.settle();

    var buffer: [core.max_client_layout_wire_bytes]u8 = undefined;
    const resized = try harness.nextClientMessage(&buffer);
    try std.testing.expect(resized == .pane_resize);
    const retained = try harness.nextClientMessage(&buffer);
    try std.testing.expect(retained == .update_client_layout);
    try std.testing.expectEqual(@as(u16, 44), retained.update_client_layout.sidebar_width);
    const detached = try harness.nextClientMessage(&buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, detached.detach_pane.pane_id);
}

test "a missing pane attachment keeps local membership until a canonical snapshot" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    const discovered: core.PaneId = @enumFromInt(11);
    var payload: [256]u8 = undefined;
    const attachment_request = try harness.discoverAndRequestAttachment(discovered, &payload);
    const version_before_failure = client.model.version();

    const failed = try core.encodeRequestFailed(&payload, .{
        .request_id = attachment_request,
        .code = .pane_not_found,
        .message = "pane disappeared",
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(failed));

    const pane = client.model.panes.find(discovered) orelse return error.PaneRemovedBeforeSnapshot;
    try std.testing.expect(!pane.attached);
    try support.expectOnlyNotificationVersionChanged(version_before_failure, client.model.version());
    try std.testing.expect(client.model.request_lifecycle.tracker.has(.tab_snapshot));
    try harness.settle();

    var message_buffer: [256]u8 = undefined;
    const recovery = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(recovery == .request_tab_snapshot);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, recovery.request_tab_snapshot.location);
    try std.testing.expect(client.model.notification_scheduler.pending);
}

test "an internal pane attachment failure waits for a later resync" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    const discovered: core.PaneId = @enumFromInt(11);
    var payload: [256]u8 = undefined;
    const attachment_request = try harness.discoverAndRequestAttachment(discovered, &payload);
    const version_before_failure = client.model.version();

    const failed = try core.encodeRequestFailed(&payload, .{
        .request_id = attachment_request,
        .code = .internal,
        .message = "resize failed",
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(failed));

    const pane = client.model.panes.find(discovered) orelse return error.PaneRemovedAfterInternalFailure;
    try std.testing.expect(!pane.attached);
    try support.expectOnlyNotificationVersionChanged(version_before_failure, client.model.version());
    try std.testing.expect(!client.model.request_lifecycle.tracker.has(.tab_snapshot));
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
    try std.testing.expect(client.model.notification_scheduler.pending);
}

test "a late pane attachment confirmation retired by a snapshot is ignored" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;

    const discovered: core.PaneId = @enumFromInt(11);
    var payload: [256]u8 = undefined;
    const attachment_request = try harness.discoverAndRequestAttachment(discovered, &payload);
    try client.model.request_lifecycle.tracker.add(@enumFromInt(90), .{ .tab_snapshot = TestHarness.bootstrap_location });

    const reconciled = try core.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(90),
        .location = TestHarness.bootstrap_location,
        .panes = &.{.{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running }},
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(reconciled));
    try std.testing.expect(client.model.panes.find(discovered) == null);
    const pending_updates_before_confirmation = terminal.presenter.pending_updates;

    const opened = try core.encodePaneOpened(&payload, .{
        .request_id = attachment_request,
        .pane_id = discovered,
        .location = TestHarness.bootstrap_location,
        .created = false,
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(opened));

    try std.testing.expectEqual(pending_updates_before_confirmation, terminal.presenter.pending_updates);
}

test "a late failed pane attachment does not notify or draw" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;

    try client.model.request_lifecycle.tracker.add(@enumFromInt(4), .{ .attach_pane = .{
        .pane_id = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
    } });
    try std.testing.expect(client.model.request_lifecycle.tracker.ignoreAttachment(TestHarness.bootstrap_pane));
    const pending_updates_before_failure = terminal.presenter.pending_updates;
    var payload: [256]u8 = undefined;
    const failed = try core.encodeRequestFailed(&payload, .{
        .request_id = @enumFromInt(4),
        .code = .pane_not_found,
        .message = "pane disappeared",
    });

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(failed));

    try std.testing.expectEqual(pending_updates_before_failure, terminal.presenter.pending_updates);
    try std.testing.expect(!client.model.notification_scheduler.pending);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

const FullscreenReattachment = struct {
    harness: *TestHarness,

    pub fn selectTab(self: FullscreenReattachment, index: u8, panes: []const core.PaneDescriptor) !void {
        const client = self.harness.client;
        _ = try client_module.actions.executeAction(
            client,
            .{
                .select_tab = index,
            },
            .effect,
        );
        try self.harness.settle();
        var buffer: [512]u8 = undefined;
        const request = request: while (true) {
            switch (try self.harness.nextClientMessage(&buffer)) {
                .detach_pane => {},
                .request_tab_snapshot => |request| break :request request,
                else => return error.UnexpectedClientMessage,
            }
        };
        const snapshot = try core.encodeTabSnapshot(&buffer, .{
            .request_id = request.request_id,
            .location = request.location,
            .panes = panes,
        });
        _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(snapshot));
        try self.confirmAttachment(client.model.tabs.layout[client.model.tabs.active].focused().?);
    }

    pub fn confirmAttachment(self: FullscreenReattachment, pane_id: core.PaneId) !void {
        const client = self.harness.client;
        const terminal = self.harness.terminal;
        try std.testing.expect(client.model.request_lifecycle.tracker.hasPane(.attachment, pane_id));
        try self.harness.settle();
        var buffer: [256]u8 = undefined;
        const message = try self.harness.nextClientMessage(&buffer);
        try std.testing.expect(message == .open_pane);
        try std.testing.expectEqualDeep(core.PaneTarget{ .pane = pane_id }, message.open_pane.target);
        try std.testing.expectEqualDeep(
            data.tab_layout.contentSize(&client.model, client.model.tabs.active, pane_id, terminal.view.workbench()).?,
            message.open_pane.size,
        );
        const opened = try core.encodePaneOpened(&buffer, .{
            .request_id = message.open_pane.request_id,
            .pane_id = pane_id,
            .location = client.model.activeTabLocation().?,
            .created = false,
        });
        _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(opened));
        try std.testing.expect(client.model.panes.find(pane_id).?.attached);
    }

    pub fn expectInput(self: FullscreenReattachment, pane_id: core.PaneId) !void {
        try std.testing.expectEqual(pane_id, self.harness.client.model.planPaneInput(.focused).?.pane_id);
        try host_inputs.key(self.harness.terminal, try data.chord.parseKey("x"));
        try self.harness.settle();
        var buffer: [256]u8 = undefined;
        const message = try self.harness.nextClientMessage(&buffer);
        try std.testing.expect(message == .pane_input);
        try std.testing.expectEqual(pane_id, message.pane_input.pane_id);
        try std.testing.expectEqualStrings("x", message.pane_input.bytes);
    }
};
