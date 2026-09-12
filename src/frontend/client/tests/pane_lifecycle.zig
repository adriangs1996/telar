//! Client integration tests for pane lifecycle.

const TerminalClient = @import("../TerminalClient.zig");
const host = TerminalClient.of;
const TestHarness = @import("TestHarness.zig");
const PaneIdType = @import("telar-core").PaneId;
const std = @import("std");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const InputHandler = @import("../resources/InputHandler.zig");
const client_actions = @import("telar-client").controllers.actions;
const FullscreenReattachment = @import("FullscreenReattachment.zig");
const PaneDescriptorType = @import("telar-core").PaneDescriptor;
const encodePaneForeground_module = @import("telar-core").encodePaneForeground;
const server_messages = @import("telar-client").server_messages;
const decodeServer_module = @import("telar-core").decodeServer;
const DirectionType = @import("telar-client").Direction;
const encodePaneFocusCommand_module = @import("telar-core").encodePaneFocusCommand;
const PaneFocusOutcomeType = @import("telar-core").PaneFocusOutcome;
const term = @import("../../presentation/screen_support.zig");
const pane_geometry = @import("telar-client").controllers.pane_geometry;
const TerminalSizeType = @import("telar-core").TerminalSize;
const sidebar_projection = @import("telar-client").controllers.sidebar_projection;
const encodePaneOpened_module = @import("telar-core").encodePaneOpened;
const TabsModel = @import("telar-client").TabsModel;
const encodeRequestFailed_module = @import("telar-core").encodeRequestFailed;
const support = @import("support.zig");
const tab_attachments = @import("telar-client").controllers.tab_attachments;
const active_pane_resources = @import("telar-client").controllers.active_pane_resources;
const ControlType = @import("telar-client").Control;
const max_client_layout_wire_bytes_module = @import("telar-core").max_client_layout_wire_bytes;
const encodeTabSnapshot_module = @import("telar-core").encodeTabSnapshot;

test "pane focus commits before reports resize and presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second: PaneIdType = @enumFromInt(20);
    const area = host(client).view.workbench();

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
    const model = &client.model.workspace.active().?.model;
    try std.testing.expect(model.toggleFullscreen());
    model.find(TestHarness.bootstrap_pane).?.input_modes.focus_events = true;
    model.find(second).?.input_modes.focus_events = true;
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();

    _ = client.model.syncReportedPaneFocus().?;
    const version_before = client.model.version();
    const pending_updates_before = host(client).presenter.pending_updates;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .{ .focus_pane = .left });

    try std.testing.expectEqual(TestHarness.bootstrap_pane, model.layout.focused().?);
    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(version_before.workspace, client.model.version().workspace);
    try std.testing.expectEqual(version_before.tabs, client.model.version().tabs);
    try std.testing.expectEqual(version_before.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before, host(client).presenter.pending_updates);
    const expected_size = model.contentSize(TestHarness.bootstrap_pane, area).?;

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

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates_before + 1, host(client).presenter.pending_updates);
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.observed.model);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);

    const version_before_noop = client.model.version();
    const pending_updates_before_noop = host(client).presenter.pending_updates;
    _ = try client_actions.apply(handler.client, .{ .focus_pane = .left });
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(version_before_noop, client.model.version());
    try std.testing.expectEqual(pending_updates_before_noop, host(client).presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "fullscreen tab round trip reconnects panes revealed by focus or tiled layout" {
    for ([_]bool{ false, true }) |exit_fullscreen| {
        var harness: TestHarness = undefined;
        try harness.init();
        defer harness.deinit();
        try harness.bootstrap();
        try harness.allowTabSelection();
        const client = harness.client;
        _ = try client.model.reconcileTab(.{
            .location = TestHarness.bootstrap_location,
            .panes = &.{TestHarness.bootstrap_pane},
        }, host(client).view.workbench());
        const sibling: PaneIdType = @enumFromInt(20);
        const other_tab_pane: PaneIdType = @enumFromInt(30);
        const model = &client.model.workspace.active().?.model;
        try model.split(.{
            .existing_pane = TestHarness.bootstrap_pane,
            .new_pane = sibling,
            .location = TestHarness.bootstrap_location,
            .axis = .horizontal,
            .area = host(client).view.workbench(),
        });
        try std.testing.expect(model.toggleFullscreen());
        _ = try harness.addInactiveTab(@enumFromInt(2), other_tab_pane);
        const scenario: FullscreenReattachment = .{ .harness = &harness };
        const original_panes = [_]PaneDescriptorType{
            .{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running },
            .{ .pane_id = sibling, .lifecycle = .running },
        };

        try scenario.selectTab(1, &.{.{ .pane_id = other_tab_pane, .lifecycle = .running }});
        try scenario.selectTab(0, &original_panes);
        try std.testing.expect(model.layout.isFullscreen());
        try std.testing.expect(!model.find(TestHarness.bootstrap_pane).?.attached);
        try scenario.expectInput(sibling);

        if (exit_fullscreen) {
            _ = try client_actions.apply(client, .toggle_pane_fullscreen);
            try harness.settle();
            var buffer: [256]u8 = undefined;
            const resize = try harness.nextClientMessage(&buffer);
            try std.testing.expect(resize == .pane_resize);
            try std.testing.expectEqual(sibling, resize.pane_resize.pane_id);
        } else {
            _ = try client_actions.apply(client, .{ .focus_pane = .left });
            _ = try client_actions.apply(client, .{ .focus_pane = .right });
            _ = try client_actions.apply(client, .{ .focus_pane = .left });
        }

        try scenario.confirmAttachment(TestHarness.bootstrap_pane);
        if (exit_fullscreen) {
            _ = try client_actions.apply(client, .{ .focus_pane = .left });
        } else {
            // Returning to the attached sibling resized it, but did not duplicate the pending open.
            var buffer: [256]u8 = undefined;
            const resize = try harness.nextClientMessage(&buffer);
            try std.testing.expect(resize == .pane_resize);
            try std.testing.expectEqual(sibling, resize.pane_resize.pane_id);
        }

        try scenario.expectInput(TestHarness.bootstrap_pane);
        _ = try client_actions.apply(client, .{ .focus_pane = .right });
        if (!exit_fullscreen) {
            try harness.settle();
            var buffer: [256]u8 = undefined;
            try std.testing.expect((try harness.nextClientMessage(&buffer)) == .pane_resize);
        }

        try scenario.expectInput(sibling);
        try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    }
}

test "navigation forwards the canonical key only to Neovim at a Telar edge" {
    for ([_][]const u8{ "nvim", "zsh" }) |foreground_name| {
        var harness: TestHarness = undefined;
        try harness.init();
        defer harness.deinit();
        try harness.bootstrap();

        var payload: [128]u8 = undefined;
        const foreground = try encodePaneForeground_module(&payload, .{
            .pane_id = TestHarness.bootstrap_pane,
            .name = foreground_name,
        });
        _ = try server_messages.handleServerMessage(harness.client, try decodeServer_module(foreground));

        if (!std.mem.eql(u8, foreground_name, "nvim")) {
            const version = harness.client.model.version();
            for (std.enums.values(DirectionType)) |direction| {
                _ = try client_actions.apply(harness.client, .{ .navigate_pane = direction });
                try std.testing.expectEqualDeep(version, harness.client.model.version());
                try std.testing.expectEqual(@as(usize, 0), harness.client.runtime_transport.outbox.len);
            }

            continue;
        }

        _ = try client_actions.apply(harness.client, .{ .navigate_pane = .left });
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
    const command = try encodePaneFocusCommand_module(&payload, .{
        .requester = .{ .id = 8, .generation = 9 },
        .request_id = @enumFromInt(3),
        .pane_id = TestHarness.bootstrap_pane,
        .pane_generation = 4,
        .direction = .left,
    });
    _ = try server_messages.handleServerMessage(harness.client, try decodeServer_module(command));
    try harness.settle();

    var message_buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(message == .complete_pane_focus);
    try std.testing.expectEqual(PaneFocusOutcomeType.no_neighbor, message.complete_pane_focus.outcome);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, message.complete_pane_focus.focused_pane_id);
}

test "navigation lets Neovim consume internal movement before Telar focus" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second: PaneIdType = @enumFromInt(20);
    _ = try client.model.commitPaneSplit(.{
        .split = .{
            .target_pane = TestHarness.bootstrap_pane,
            .location = TestHarness.bootstrap_location,
            .axis = .horizontal,
            .area = host(client).view.workbench(),
        },
        .new_pane = second,
    });

    var payload: [128]u8 = undefined;
    const nvim = try encodePaneForeground_module(&payload, .{ .pane_id = second, .name = "nvim" });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(nvim));
    _ = try client_actions.apply(client, .{ .navigate_pane = .left });
    try std.testing.expectEqual(second, client.model.workspace.active().?.model.layout.focused().?);
    try harness.settle();

    var message_buffer: [256]u8 = undefined;
    const forwarded = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(forwarded == .pane_input);
    try std.testing.expectEqual(second, forwarded.pane_input.pane_id);

    const shell = try encodePaneForeground_module(&payload, .{ .pane_id = second, .name = "zsh" });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(shell));
    _ = try client_actions.apply(client, .{ .navigate_pane = .left });
    try std.testing.expectEqual(TestHarness.bootstrap_pane, client.model.workspace.active().?.model.layout.focused().?);
}

test "mouse focus precedes forwarding its triggering press" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const first = TestHarness.bootstrap_pane;
    const second: PaneIdType = @enumFromInt(20);
    const area = host(client).view.workbench();

    _ = try client.model.commitPaneSplit(.{
        .split = .{
            .target_pane = first,
            .location = TestHarness.bootstrap_location,
            .axis = .horizontal,
            .area = area,
        },
        .new_pane = second,
    });
    const model = &client.model.workspace.active().?.model;
    model.find(first).?.input_modes.focus_events = true;
    model.find(first).?.mouse = .{ .tracking = .normal, .sgr = true };
    model.find(second).?.input_modes.focus_events = true;
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();

    _ = client.model.syncReportedPaneFocus().?;
    const first_view = model.viewForPane(first, area).?;
    const point = term.Event.Mouse{
        .x = first_view.content.x,
        .y = first_view.content.y,
        .kind = .move,
    };
    var handler: InputHandler = .{ .client = client };
    try handler.mouse(point);
    const version_before = client.model.version();
    var press = point;
    press.kind = .press;

    try handler.mouse(press);

    try std.testing.expectEqual(first, model.layout.focused().?);
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
    const area = host(client).view.workbench();
    const active = &client.model.workspace.active().?.model;
    const expected_size = active.contentSize(TestHarness.bootstrap_pane, area).?;

    try pane_geometry.offerAttached(client, active, area);
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const offered = try harness.nextClientMessage(&buffer);
    try std.testing.expect(offered == .pane_resize);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, offered.pane_resize.pane_id);
    try std.testing.expectEqual(expected_size, offered.pane_resize.size);

    const detached_location = try harness.addInactiveTab(@enumFromInt(2), @enumFromInt(20));
    const detached = &client.model.workspace.find(detached_location.tab_id).?.model;
    try pane_geometry.offerAttached(client, detached, area);

    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expect(!client.runtime_transport.outbox.inFlight());
}

test "pane resize publishes committed geometry before presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const first = TestHarness.bootstrap_pane;
    const second: PaneIdType = @enumFromInt(20);
    const area = host(client).view.workbench();

    _ = try client.model.commitPaneSplit(.{
        .split = .{
            .target_pane = first,
            .location = TestHarness.bootstrap_location,
            .axis = .horizontal,
            .area = area,
        },
        .new_pane = second,
    });
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    const model = &client.model.workspace.active().?.model;
    const first_before = model.contentSize(first, area).?;
    const second_before = model.contentSize(second, area).?;
    const version_before = client.model.version();
    const pending_updates_before = host(client).presenter.pending_updates;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .{ .resize_pane = .left });

    const first_after = model.contentSize(first, area).?;
    const second_after = model.contentSize(second, area).?;
    try std.testing.expect(first_after.cols < first_before.cols);
    try std.testing.expect(second_after.cols > second_before.cols);
    try std.testing.expectEqual(second, model.layout.focused().?);
    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(version_before.workspace, client.model.version().workspace);
    try std.testing.expectEqual(version_before.tabs, client.model.version().tabs);
    try std.testing.expectEqual(version_before.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before, host(client).presenter.pending_updates);
    try std.testing.expect(!host(client).view.dirty);

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

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates_before + 1, host(client).presenter.pending_updates);
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.observed.model);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);

    const version_before_noop = client.model.version();
    const pending_updates_before_noop = host(client).presenter.pending_updates;
    _ = try client_actions.apply(handler.client, .{ .resize_pane = .up });
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(version_before_noop, client.model.version());
    try std.testing.expectEqual(pending_updates_before_noop, host(client).presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expect(!host(client).view.dirty);
}

test "single-pane fullscreen publishes bordered and restored geometry" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pane_id = TestHarness.bootstrap_pane;
    const area = host(client).view.workbench();
    const model = &client.model.workspace.active().?.model;
    const initial = model.contentSize(pane_id, area).?;
    var message_buffer: [256]u8 = undefined;

    for ([_]bool{ true, false }) |fullscreen| {
        const version = client.model.version();
        const pending_updates = host(client).presenter.pending_updates;
        _ = try client_actions.apply(client, .toggle_pane_fullscreen);
        const expected = if (fullscreen)
            TerminalSizeType{ .cols = area.w - 2, .rows = area.h - 2 }
        else
            initial;
        try std.testing.expectEqual(fullscreen, model.layout.isFullscreen());
        try std.testing.expectEqual(expected, model.contentSize(pane_id, area).?);
        try std.testing.expectEqual(version.panes + 1, client.model.version().panes);
        try std.testing.expectEqual(pending_updates, host(client).presenter.pending_updates);
        try harness.settle();
        const message = try harness.nextClientMessage(&message_buffer);
        try std.testing.expect(message == .pane_resize);
        try std.testing.expectEqual(pane_id, message.pane_resize.pane_id);
        try std.testing.expectEqual(expected, message.pane_resize.size);
        try presentation_lifecycle.observe(client);
        try harness.settleModelPresentation();
        try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);
    }
}

test "pane fullscreen publishes visible geometry without direct presentation scheduling" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const first = TestHarness.bootstrap_pane;
    const second: PaneIdType = @enumFromInt(20);
    const area = host(client).view.workbench();

    _ = try client.model.commitPaneSplit(.{
        .split = .{
            .target_pane = first,
            .location = TestHarness.bootstrap_location,
            .axis = .horizontal,
            .area = area,
        },
        .new_pane = second,
    });
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    const model = &client.model.workspace.active().?.model;
    const first_tiled = model.contentSize(first, area).?;
    const second_tiled = model.contentSize(second, area).?;
    const version_before_enter = client.model.version();
    const pending_updates_before_enter = host(client).presenter.pending_updates;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .toggle_pane_fullscreen);

    try std.testing.expect(model.layout.isFullscreen());
    try std.testing.expect(model.contentSize(first, area) == null);
    const fullscreen_size = model.contentSize(second, area).?;
    try std.testing.expectEqual(TerminalSizeType{ .cols = area.w - 2, .rows = area.h - 2 }, fullscreen_size);
    try std.testing.expectEqual(version_before_enter.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_enter, host(client).presenter.pending_updates);
    try std.testing.expect(!host(client).view.dirty);

    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const fullscreen_resize = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(fullscreen_resize == .pane_resize);
    try std.testing.expectEqual(second, fullscreen_resize.pane_resize.pane_id);
    try std.testing.expectEqual(fullscreen_size, fullscreen_resize.pane_resize.size);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates_before_enter + 1, host(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);

    const version_before_exit = client.model.version();
    const pending_updates_before_exit = host(client).presenter.pending_updates;
    _ = try client_actions.apply(handler.client, .toggle_pane_fullscreen);

    try std.testing.expect(!model.layout.isFullscreen());
    try std.testing.expectEqual(first_tiled, model.contentSize(first, area).?);
    try std.testing.expectEqual(second_tiled, model.contentSize(second, area).?);
    try std.testing.expectEqual(version_before_exit.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_exit, host(client).presenter.pending_updates);
    try std.testing.expect(!host(client).view.dirty);

    try harness.settle();
    const first_resize = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(first_resize == .pane_resize);
    try std.testing.expectEqual(first, first_resize.pane_resize.pane_id);
    try std.testing.expectEqual(first_tiled, first_resize.pane_resize.size);
    const second_resize = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(second_resize == .pane_resize);
    try std.testing.expectEqual(second, second_resize.pane_resize.pane_id);
    try std.testing.expectEqual(second_tiled, second_resize.pane_resize.size);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates_before_exit + 1, host(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);
}

test "sidebar toggle commits chrome before geometry and presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const shown_area = host(client).view.workbench();
    const version_before_hide = client.model.version();
    const pending_updates_before_hide = host(client).presenter.pending_updates;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .toggle_sidebar);

    const hidden_area = host(client).view.workbench();
    try std.testing.expect(hidden_area.w > shown_area.w);
    try std.testing.expect(!client.model.sidebarVisible());
    try std.testing.expect(!host(client).view.sidebar_requested);
    try std.testing.expectEqual(version_before_hide.chrome + 1, client.model.version().chrome);
    try std.testing.expectEqual(version_before_hide.workspace, client.model.version().workspace);
    try std.testing.expectEqual(version_before_hide.tabs, client.model.version().tabs);
    try std.testing.expectEqual(version_before_hide.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(version_before_hide.panes, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_hide, host(client).presenter.pending_updates);
    try std.testing.expect(host(client).view.dirty);

    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const expanded = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(expanded == .pane_resize);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, expanded.pane_resize.pane_id);
    try std.testing.expectEqual(
        TerminalSizeType{ .cols = hidden_area.w, .rows = hidden_area.h },
        expanded.pane_resize.size,
    );

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_hide + 1, host(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);
    try std.testing.expect(!host(client).view.dirty);

    const version_before_show = client.model.version();
    const pending_updates_before_show = host(client).presenter.pending_updates;
    _ = try client_actions.apply(handler.client, .toggle_sidebar);

    try std.testing.expect(client.model.sidebarVisible());
    try std.testing.expect(host(client).view.sidebar_requested);
    try std.testing.expectEqualDeep(shown_area, host(client).view.workbench());
    try std.testing.expectEqual(version_before_show.chrome + 1, client.model.version().chrome);
    try std.testing.expectEqual(pending_updates_before_show, host(client).presenter.pending_updates);

    try harness.settle();
    const contracted = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(contracted == .pane_resize);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, contracted.pane_resize.pane_id);
    try std.testing.expectEqual(
        TerminalSizeType{ .cols = shown_area.w, .rows = shown_area.h },
        contracted.pane_resize.size,
    );

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_show + 1, host(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);
}

test "sidebar resize keybinding commits width before pane geometry" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version = client.model.version();

    _ = try client_actions.apply(client, .{ .resize_sidebar = .right });

    try std.testing.expectEqual(@as(u16, 44), client.model.sidebarWidth());
    try std.testing.expectEqual(@as(u16, 44), host(client).view.regions.sidebar.w);
    try std.testing.expectEqual(version.chrome + 1, client.model.version().chrome);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const resized = try harness.nextClientMessage(&buffer);
    try std.testing.expect(resized == .pane_resize);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, resized.pane_resize.pane_id);
    try std.testing.expectEqual(
        TerminalSizeType{ .cols = 36, .rows = 22 },
        resized.pane_resize.size,
    );
}

test "sidebar projection rejects changes that are not the current model commit" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    host(client).view.dirty = false;
    host(client).graphics_store.damage = false;
    const shown_area = host(client).view.workbench();
    const committed = client.model.toggleSidebar();

    try std.testing.expectError(error.StaleSidebarLayout, sidebar_projection.apply(client, .{
        .visible = true,
        .chrome_revision = committed.chrome_revision - 1,
    }));
    try std.testing.expectError(error.StaleSidebarLayout, sidebar_projection.apply(client, .{
        .visible = committed.visible,
        .chrome_revision = committed.chrome_revision - 1,
    }));

    try std.testing.expect(host(client).view.sidebar_requested);
    try std.testing.expectEqualDeep(shown_area, host(client).view.workbench());
    try std.testing.expect(!host(client).view.dirty);
    try std.testing.expect(!host(client).graphics_store.damage);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);

    try sidebar_projection.apply(client, committed);

    try std.testing.expect(!host(client).view.sidebar_requested);
    try std.testing.expect(host(client).view.workbench().w > shown_area.w);
    try std.testing.expect(host(client).view.dirty);
    try std.testing.expect(host(client).graphics_store.damage);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "workspace list toggle is projected only by the presenter" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before_collapse = client.model.version();
    const pending_updates_before_collapse = host(client).presenter.pending_updates;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .toggle_workspace_list);

    try std.testing.expect(client.model.workspaceListCollapsed());
    try std.testing.expect(!host(client).view.workspace_list_collapsed);
    try std.testing.expectEqual(version_before_collapse.chrome + 1, client.model.version().chrome);
    try std.testing.expectEqual(version_before_collapse.workspace, client.model.version().workspace);
    try std.testing.expectEqual(version_before_collapse.tabs, client.model.version().tabs);
    try std.testing.expectEqual(version_before_collapse.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(version_before_collapse.panes, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_collapse, host(client).presenter.pending_updates);
    try std.testing.expect(!host(client).view.dirty);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_collapse + 1, host(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expect(host(client).view.workspace_list_collapsed);
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);

    const version_before_expand = client.model.version();
    const pending_updates_before_expand = host(client).presenter.pending_updates;
    _ = try client_actions.apply(handler.client, .toggle_workspace_list);

    try std.testing.expect(!client.model.workspaceListCollapsed());
    try std.testing.expect(host(client).view.workspace_list_collapsed);
    try std.testing.expectEqual(version_before_expand.chrome + 1, client.model.version().chrome);
    try std.testing.expectEqual(pending_updates_before_expand, host(client).presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_expand + 1, host(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expect(!host(client).view.workspace_list_collapsed);
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);
}

test "an active split commits once and presentation observes the model" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    const split_pane: PaneIdType = @enumFromInt(21);
    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .split = .{
        .target_pane = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .axis = .horizontal,
        .area = host(client).view.workbench(),
    } });
    const version_before = client.model.version();
    const pending_updates_before = host(client).presenter.pending_updates;
    var payload: [128]u8 = undefined;
    const opened = try encodePaneOpened_module(&payload, .{
        .request_id = @enumFromInt(4),
        .pane_id = split_pane,
        .location = TestHarness.bootstrap_location,
        .created = true,
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(opened));

    const pane = client.model.workspace.findPane(split_pane).?;
    try std.testing.expect(pane.attached);
    try std.testing.expectEqual(split_pane, client.model.workspace.active().?.model.layout.focused().?);
    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before, host(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before + 1, host(client).presenter.pending_updates);
}

test "an inactive split is retained detached without a visible revision" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const first = client.model.workspace.active().?;
    const second_location = try harness.addTab(@enumFromInt(2), @enumFromInt(20));
    TabsModel.detachAll(first);
    try std.testing.expectEqualDeep(second_location, client.model.activeTabLocation().?);

    const split_pane: PaneIdType = @enumFromInt(21);
    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .split = .{
        .target_pane = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .axis = .horizontal,
        .area = host(client).view.workbench(),
    } });
    const version_before = client.model.version();
    const pending_updates_before = host(client).presenter.pending_updates;
    var payload: [128]u8 = undefined;
    const opened = try encodePaneOpened_module(&payload, .{
        .request_id = @enumFromInt(4),
        .pane_id = split_pane,
        .location = TestHarness.bootstrap_location,
        .created = true,
    });

    _ = try server_messages.handleServerMessage(client, try decodeServer_module(opened));

    try std.testing.expect(!client.model.workspace.findPane(split_pane).?.attached);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, host(client).presenter.pending_updates);
    try std.testing.expect(!host(client).graphics_store.paneVisible(split_pane));
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
    _ = client.request_lifecycle.tracker.take(@enumFromInt(2)) orelse return error.MissingWorkspaceSnapshot;
    _ = try harness.addTab(@enumFromInt(2), @enumFromInt(20));

    const split_pane: PaneIdType = @enumFromInt(21);
    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .split = .{
        .target_pane = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .axis = .horizontal,
        .area = host(client).view.workbench(),
    } });
    client.request_lifecycle.tracker.ignoreTab(TestHarness.bootstrap_location.tab_id);
    try std.testing.expect(client.model.workspace.remove(TestHarness.bootstrap_location.tab_id));
    const version_before = client.model.version();
    const pending_updates_before = host(client).presenter.pending_updates;
    var payload: [128]u8 = undefined;
    const opened = try encodePaneOpened_module(&payload, .{
        .request_id = @enumFromInt(4),
        .pane_id = split_pane,
        .location = TestHarness.bootstrap_location,
        .created = true,
    });

    _ = try server_messages.handleServerMessage(client, try decodeServer_module(opened));

    try std.testing.expect(client.model.workspace.findPane(split_pane) == null);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, host(client).presenter.pending_updates);
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

    const split_pane: PaneIdType = @enumFromInt(21);
    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .split = .{
        .target_pane = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .axis = .horizontal,
        .area = host(client).view.workbench(),
    } });
    try std.testing.expect(client.model.workspace.active().?.model.removePane(TestHarness.bootstrap_pane));
    client.request_lifecycle.tracker.ignorePane(TestHarness.bootstrap_pane);
    const version_before = client.model.version();
    var payload: [128]u8 = undefined;
    const opened = try encodePaneOpened_module(&payload, .{
        .request_id = @enumFromInt(4),
        .pane_id = split_pane,
        .location = TestHarness.bootstrap_location,
        .created = true,
    });

    _ = try server_messages.handleServerMessage(client, try decodeServer_module(opened));

    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane) == null);
    try std.testing.expect(client.model.workspace.findPane(split_pane).?.attached);
    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
}

test "a failed split never resizes the tab selected afterwards" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const first = client.model.workspace.active().?;
    _ = try harness.addTab(@enumFromInt(2), @enumFromInt(20));
    TabsModel.detachAll(first);

    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .split = .{
        .target_pane = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .axis = .horizontal,
        .area = host(client).view.workbench(),
    } });
    const version_before = client.model.version();
    var payload: [128]u8 = undefined;
    const failed = try encodeRequestFailed_module(&payload, .{
        .request_id = @enumFromInt(4),
        .code = .internal,
        .message = "launch failed",
    });

    _ = try server_messages.handleServerMessage(client, try decodeServer_module(failed));

    try std.testing.expectEqual(@as(u8, 0), client.runtime_transport.outbox.len);
    try support.expectOnlyNotificationVersionChanged(version_before, client.model.version());
}

test "a failed split for a retired target is silent" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .split = .{
        .target_pane = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .axis = .horizontal,
        .area = host(client).view.workbench(),
    } });
    try std.testing.expect(client.model.workspace.active().?.model.removePane(TestHarness.bootstrap_pane));
    client.request_lifecycle.tracker.ignorePane(TestHarness.bootstrap_pane);
    const pending_updates_before = host(client).presenter.pending_updates;
    var payload: [128]u8 = undefined;
    const failed = try encodeRequestFailed_module(&payload, .{
        .request_id = @enumFromInt(4),
        .code = .pane_not_found,
        .message = "target exited",
    });

    _ = try server_messages.handleServerMessage(client, try decodeServer_module(failed));

    try std.testing.expectEqual(@as(u8, 0), client.runtime_transport.outbox.len);
    try std.testing.expectEqual(pending_updates_before, host(client).presenter.pending_updates);
}

test "an attach reply marks the discovered pane attached" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    const discovered: PaneIdType = @enumFromInt(11);
    var payload: [256]u8 = undefined;
    const attachment_request = try harness.discoverAndRequestAttachment(discovered, &payload);
    try std.testing.expect(!client.model.workspace.findPane(discovered).?.attached);

    const version_before_confirmation = client.model.version();
    const pending_updates_before_confirmation = host(client).presenter.pending_updates;

    const opened = try encodePaneOpened_module(&payload, .{
        .request_id = attachment_request,
        .pane_id = discovered,
        .location = TestHarness.bootstrap_location,
        .created = false,
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(opened));

    try std.testing.expect(client.model.workspace.findPane(discovered).?.attached);
    try std.testing.expectEqualDeep(version_before_confirmation, client.model.version());
    try std.testing.expectEqual(pending_updates_before_confirmation, host(client).presenter.pending_updates);
}

test "tab detachment retires an in-flight pane attachment" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    const discovered: PaneIdType = @enumFromInt(11);
    var payload: [256]u8 = undefined;
    const attachment_request = try harness.discoverAndRequestAttachment(discovered, &payload);
    try tab_attachments.detach(client, client.model.workspace.active().?.location);
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
    try std.testing.expect(!client.request_lifecycle.tracker.hasPane(.attachment, discovered));

    const pending_updates_before_confirmation = host(client).presenter.pending_updates;
    const opened = try encodePaneOpened_module(&payload, .{
        .request_id = attachment_request,
        .pane_id = discovered,
        .location = TestHarness.bootstrap_location,
        .created = false,
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(opened));

    try std.testing.expect(!client.model.workspace.findPane(discovered).?.attached);
    try std.testing.expectEqual(pending_updates_before_confirmation, host(client).presenter.pending_updates);
}

test "tab detachment closes a captured bracketed paste before the pane detaches" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.workspace.findPane(TestHarness.bootstrap_pane).?.input_modes.bracketed_paste = true;
    var handler: InputHandler = .{ .client = client };

    try handler.pasteStart();
    try harness.settle();

    var message_buffer: [256]u8 = undefined;
    const opening = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(opening == .pane_input);
    try std.testing.expectEqualStrings("\x1b[200~", opening.pane_input.bytes);

    try tab_attachments.detach(client, client.model.workspace.active().?.location);

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
    client.model.workspace.findPane(TestHarness.bootstrap_pane).?.input_modes.focus_events = true;

    try active_pane_resources.synchronize(client);
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const focus_in = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(focus_in == .pane_input);
    try std.testing.expectEqualStrings("\x1b[I", focus_in.pane_input.bytes);

    try tab_attachments.detach(client, client.model.workspace.active().?.location);

    try std.testing.expect(client.model.reportedPaneFocus() == null);
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
    client.model.workspace.findPane(TestHarness.bootstrap_pane).?.input_modes.focus_events = true;
    try active_pane_resources.synchronize(client);
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const focus_in = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(focus_in == .pane_input);
    try std.testing.expectEqualStrings("\x1b[I", focus_in.pane_input.bytes);

    const inactive_pane: PaneIdType = @enumFromInt(20);
    const inactive = try harness.addInactiveTab(@enumFromInt(2), inactive_pane);
    const tab = client.model.workspace.find(inactive.tab_id).?;
    tab.model.find(inactive_pane).?.attached = true;
    const reported = client.model.reportedPaneFocus().?;

    try tab_attachments.detach(client, tab.location);

    try std.testing.expectEqualDeep(reported, client.model.reportedPaneFocus().?);
    try harness.settle();
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(inactive_pane, detached.detach_pane.pane_id);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "detach action releases every tab before stopping the client" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second_pane: PaneIdType = @enumFromInt(20);
    _ = try harness.addTab(@enumFromInt(2), second_pane);
    const version = client.model.version();
    const pending_updates = host(client).presenter.pending_updates;

    try std.testing.expectEqual(
        ControlType.stop,
        try client_actions.apply(client, .detach),
    );

    try std.testing.expect(!client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expect(!client.model.workspace.findPane(second_pane).?.attached);
    try std.testing.expect(!host(client).graphics_store.paneVisible(TestHarness.bootstrap_pane));
    try std.testing.expect(!host(client).graphics_store.paneVisible(second_pane));
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(pending_updates, host(client).presenter.pending_updates);

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
    const active = client.model.workspace.active().?;
    active.snapshot_loaded = true;
    try client.client_layouts.markSnapshotReceived();

    _ = try client_actions.apply(client, .{ .resize_sidebar = .right });
    try std.testing.expectEqual(ControlType.stop, try client_actions.apply(client, .detach));
    try harness.settle();

    var buffer: [max_client_layout_wire_bytes_module]u8 = undefined;
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

    const discovered: PaneIdType = @enumFromInt(11);
    var payload: [256]u8 = undefined;
    const attachment_request = try harness.discoverAndRequestAttachment(discovered, &payload);
    const version_before_failure = client.model.version();

    const failed = try encodeRequestFailed_module(&payload, .{
        .request_id = attachment_request,
        .code = .pane_not_found,
        .message = "pane disappeared",
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(failed));

    const pane = client.model.workspace.findPane(discovered) orelse return error.PaneRemovedBeforeSnapshot;
    try std.testing.expect(!pane.attached);
    try support.expectOnlyNotificationVersionChanged(version_before_failure, client.model.version());
    try std.testing.expect(client.request_lifecycle.tracker.has(.tab_snapshot));
    try harness.settle();

    var message_buffer: [256]u8 = undefined;
    const recovery = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(recovery == .request_tab_snapshot);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, recovery.request_tab_snapshot.location);
    try std.testing.expect(client.notification_scheduler.pending);
}

test "an internal pane attachment failure waits for a later resync" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    const discovered: PaneIdType = @enumFromInt(11);
    var payload: [256]u8 = undefined;
    const attachment_request = try harness.discoverAndRequestAttachment(discovered, &payload);
    const version_before_failure = client.model.version();

    const failed = try encodeRequestFailed_module(&payload, .{
        .request_id = attachment_request,
        .code = .internal,
        .message = "resize failed",
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(failed));

    const pane = client.model.workspace.findPane(discovered) orelse return error.PaneRemovedAfterInternalFailure;
    try std.testing.expect(!pane.attached);
    try support.expectOnlyNotificationVersionChanged(version_before_failure, client.model.version());
    try std.testing.expect(!client.request_lifecycle.tracker.has(.tab_snapshot));
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expect(client.notification_scheduler.pending);
}

test "a late pane attachment confirmation retired by a snapshot is ignored" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    const discovered: PaneIdType = @enumFromInt(11);
    var payload: [256]u8 = undefined;
    const attachment_request = try harness.discoverAndRequestAttachment(discovered, &payload);
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{ .tab_snapshot = TestHarness.bootstrap_location });

    const reconciled = try encodeTabSnapshot_module(&payload, .{
        .request_id = @enumFromInt(90),
        .location = TestHarness.bootstrap_location,
        .panes = &.{.{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running }},
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(reconciled));
    try std.testing.expect(client.model.workspace.findPane(discovered) == null);
    const pending_updates_before_confirmation = host(client).presenter.pending_updates;

    const opened = try encodePaneOpened_module(&payload, .{
        .request_id = attachment_request,
        .pane_id = discovered,
        .location = TestHarness.bootstrap_location,
        .created = false,
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(opened));

    try std.testing.expectEqual(pending_updates_before_confirmation, host(client).presenter.pending_updates);
}

test "a late failed pane attachment does not notify or draw" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .attach_pane = .{
        .pane_id = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
    } });
    try std.testing.expect(client.request_lifecycle.tracker.ignoreAttachment(TestHarness.bootstrap_pane));
    const pending_updates_before_failure = host(client).presenter.pending_updates;
    var payload: [256]u8 = undefined;
    const failed = try encodeRequestFailed_module(&payload, .{
        .request_id = @enumFromInt(4),
        .code = .pane_not_found,
        .message = "pane disappeared",
    });

    _ = try server_messages.handleServerMessage(client, try decodeServer_module(failed));

    try std.testing.expectEqual(pending_updates_before_failure, host(client).presenter.pending_updates);
    try std.testing.expect(!client.notification_scheduler.pending);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}
