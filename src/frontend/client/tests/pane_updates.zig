//! Client integration tests for pane updates.

const TerminalClient = @import("../TerminalClient.zig");
const host = TerminalClient.of;
const TestHarness = @import("TestHarness.zig");
const encodePaneFrame_module = @import("telar-core").encodePaneFrame;
const server_messages = @import("telar-client").server_messages;
const decodeServer_module = @import("telar-core").decodeServer;
const std = @import("std");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const enabled_module = @import("telar-core").enabled;
const CellType = @import("telar-core").Cell;
const encodePaneCwd_module = @import("telar-core").encodePaneCwd;
const encodePaneForeground_module = @import("telar-core").encodePaneForeground;
const PaneIdType = @import("telar-core").PaneId;
const InputHandler = @import("../resources/InputHandler.zig");
const client_actions = @import("telar-client").controllers.actions;
const encodePaneExited_module = @import("telar-core").encodePaneExited;
const support = @import("support.zig");
const pane_closures = @import("telar-client").controllers.pane_closures;
const workspace_handoffs = @import("telar-client").controllers.workspace_handoffs;
const runtime_transport = @import("telar-client").runtime_io;
const encodePaneOpened_module = @import("telar-core").encodePaneOpened;
const TabLocationType = @import("telar-core").TabLocation;
const IconType = @import("telar-client").Icon;

test "a patch against an unknown base requests a fresh snapshot" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version = client.model.version();
    const pending_updates = host(client).presenter.pending_updates;
    const frames = client.telemetry.metrics.frames;

    var payload: [512]u8 = undefined;
    const patch = try encodePaneFrame_module(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .frame_id = 5,
        .base_frame_id = 4,
        .cols = 40,
        .rows = 10,
        .scroll = .{ .total_rows = 10, .offset = 0 },
        .spans = &.{},
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(patch));
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(pending_updates, host(client).presenter.pending_updates);
    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates, host(client).presenter.pending_updates);
    if (comptime enabled_module) {
        try std.testing.expectEqual(frames, client.telemetry.metrics.frames);
    }

    try harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .request_snapshot);
    try std.testing.expectEqual(@as(u64, 0), message.request_snapshot.known_frame_id);

    // A full snapshot must carry exactly one span covering the whole grid.
    const blank: CellType = .{};
    const cells: [4]CellType = @splat(blank);
    try host(client).graphics_store.setPaneVisible(TestHarness.bootstrap_pane, false);
    const snapshot = try encodePaneFrame_module(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .frame_id = 5,
        .base_frame_id = 0,
        .cols = 2,
        .rows = 2,
        .scroll = .{ .total_rows = 2, .offset = 0 },
        .spans = &.{.{ .start = 0, .cells = &cells }},
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(snapshot));
    const pane = client.model.workspace.findPane(TestHarness.bootstrap_pane).?;

    try std.testing.expectEqual(
        @as(u64, 5),
        pane.applied_frame_id,
    );
    try std.testing.expectEqual(@as(u64, 5), pane.pending_frame_id);
    try std.testing.expectEqual(version.frame + 1, client.model.version().frame);
    try std.testing.expectEqual(pending_updates, host(client).presenter.pending_updates);
    try std.testing.expect(host(client).graphics_store.paneVisible(TestHarness.bootstrap_pane));
    if (comptime enabled_module) {
        try std.testing.expectEqual(frames + 1, client.telemetry.metrics.frames);
        try std.testing.expectEqual(@as(u64, 1), client.telemetry.metrics.snapshots);
        try std.testing.expectEqual(@as(u64, 1), client.telemetry.metrics.frame_spans);
        try std.testing.expectEqual(@as(u64, 4), client.telemetry.metrics.frame_cells);
    }

    const ack = try harness.nextClientMessage(&buffer);
    try std.testing.expect(ack == .frame_ack);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, ack.frame_ack.pane_id);
    try std.testing.expectEqual(@as(u64, 5), ack.frame_ack.frame_id);
    try std.testing.expectEqual(@as(u64, 5), pane.pending_frame_id);
    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates + 1, host(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(@as(u64, 0), pane.pending_frame_id);
    try harness.settle();
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
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
    const pending_updates = host(client).presenter.pending_updates;
    const graphics_visible = host(client).graphics_store.paneVisible(TestHarness.bootstrap_pane);
    const frames = client.telemetry.metrics.frames;
    const cells = [_]CellType{.{}};
    var payload: [256]u8 = undefined;
    const snapshot = try encodePaneFrame_module(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .frame_id = 8,
        .base_frame_id = 0,
        .cols = 1,
        .rows = 1,
        .scroll = .{ .total_rows = 1, .offset = 0 },
        .spans = &.{.{ .start = 0, .cells = &cells }},
    });

    _ = try server_messages.handleServerMessage(client, try decodeServer_module(snapshot));

    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(@as(u64, 0), pane.applied_frame_id);
    try std.testing.expectEqual(@as(u64, 0), pane.pending_frame_id);
    try std.testing.expectEqual(graphics_visible, host(client).graphics_store.paneVisible(pane.id));
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    if (comptime enabled_module) {
        try std.testing.expectEqual(frames, client.telemetry.metrics.frames);
    }

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates, host(client).presenter.pending_updates);
}

test "a frame already sent before workspace departure is harmless during handoff" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};

    const cells = [_]CellType{.{}};
    var payload: [256]u8 = undefined;
    const snapshot = try encodePaneFrame_module(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .frame_id = 8,
        .base_frame_id = 0,
        .cols = 1,
        .rows = 1,
        .scroll = .{ .total_rows = 1, .offset = 0 },
        .spans = &.{.{ .start = 0, .cells = &cells }},
    });

    // The runtime writes this frame before it can observe the client's detach.
    try harness.peer.send(std.testing.io, snapshot);
    _ = try workspace_handoffs.requestWorkspace(client, @enumFromInt(2));
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const detached = try harness.nextClientMessage(&buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, detached.detach_pane.pane_id);
    const opened = try harness.nextClientMessage(&buffer);
    try std.testing.expect(opened == .open_pane);
    try std.testing.expect(opened.open_pane.target == .workspace);
    try std.testing.expectEqual(@as(u64, 2), @intFromEnum(opened.open_pane.target.workspace));
    try std.testing.expect(client.model.workspaceLocation() == null);
    const version = client.model.version();
    const pending_updates = host(client).presenter.pending_updates;
    const graphics_version = host(client).graphics_store.ingressVersion();
    const graphics_visible = host(client).graphics_store.paneVisible(TestHarness.bootstrap_pane);
    const frames = client.telemetry.metrics.frames;

    try runtime_transport.scheduleRead(client);
    switch (try host(client).inbox.receive()) {
        .server => |result| try std.testing.expectEqual(
            @as(?u8, null),
            try runtime_transport.handleRead(client, result),
        ),
        else => return error.UnexpectedEvent,
    }

    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane) == null);
    try std.testing.expectEqual(pending_updates, host(client).presenter.pending_updates);
    try std.testing.expectEqual(graphics_version, host(client).graphics_store.ingressVersion());
    try std.testing.expectEqual(graphics_visible, host(client).graphics_store.paneVisible(TestHarness.bootstrap_pane));
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    if (comptime enabled_module) {
        try std.testing.expectEqual(frames, client.telemetry.metrics.frames);
    }

    const destination_pane: PaneIdType = @enumFromInt(20);
    const destination: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(2),
    };
    const arrived = try encodePaneOpened_module(&payload, .{
        .request_id = opened.open_pane.request_id,
        .pane_id = destination_pane,
        .location = destination,
        .created = false,
    });
    try harness.peer.send(std.testing.io, arrived);
    switch (try host(client).inbox.receive()) {
        .server => |result| try std.testing.expectEqual(
            @as(?u8, null),
            try runtime_transport.handleRead(client, result),
        ),
        else => return error.UnexpectedEvent,
    }

    try std.testing.expectEqualDeep(destination.workspace, client.model.workspaceLocation().?);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane) == null);
    const pane = client.model.workspace.findPane(destination_pane).?;
    try std.testing.expect(pane.attached);
    try harness.settle();
    const workspace_snapshot = try harness.nextClientMessage(&buffer);
    try std.testing.expect(workspace_snapshot == .request_workspace_snapshot);
    const tab_snapshot = try harness.nextClientMessage(&buffer);
    try std.testing.expect(tab_snapshot == .request_tab_snapshot);
    try std.testing.expectEqualDeep(destination, tab_snapshot.request_tab_snapshot.location);

    var destination_cells = [_]CellType{.{}};
    destination_cells[0].bytes[0] = 'N';
    const destination_snapshot = try encodePaneFrame_module(&payload, .{
        .pane_id = destination_pane,
        .frame_id = 9,
        .base_frame_id = 0,
        .cols = 1,
        .rows = 1,
        .scroll = .{ .total_rows = 1, .offset = 0 },
        .spans = &.{.{ .start = 0, .cells = &destination_cells }},
    });
    const arrival_version = client.model.version();
    try harness.peer.send(std.testing.io, destination_snapshot);
    switch (try host(client).inbox.receive()) {
        .server => |result| try std.testing.expectEqual(
            @as(?u8, null),
            try runtime_transport.handleRead(client, result),
        ),
        else => return error.UnexpectedEvent,
    }

    try std.testing.expectEqual(@as(u64, 9), pane.applied_frame_id);
    try std.testing.expectEqual(@as(u64, 9), pane.pending_frame_id);
    try std.testing.expectEqualStrings("N", pane.buffer.cells[0].text());
    try std.testing.expectEqual(arrival_version.frame + 1, client.model.version().frame);
    if (comptime enabled_module) {
        try std.testing.expectEqual(frames + 1, client.telemetry.metrics.frames);
    }

    try harness.settle();
    const ack = try harness.nextClientMessage(&buffer);
    try std.testing.expect(ack == .frame_ack);
    try std.testing.expectEqual(destination_pane, ack.frame_ack.pane_id);
    try std.testing.expectEqual(@as(u64, 9), ack.frame_ack.frame_id);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "pane cwd commits before presenter-owned metadata projection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version = client.model.version();
    const pending_updates = host(client).presenter.pending_updates;

    var payload: [128]u8 = undefined;
    const cwd = try encodePaneCwd_module(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .cwd = "/work/telar",
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(cwd));

    try std.testing.expectEqualStrings(
        "/work/telar",
        client.model.workspace.findPane(TestHarness.bootstrap_pane).?.cwdSlice(),
    );
    try std.testing.expectEqual(version.pane_metadata + 1, client.model.version().pane_metadata);
    try std.testing.expectEqual(version.pane_foreground, client.model.version().pane_foreground);
    try std.testing.expectEqual(pending_updates, host(client).presenter.pending_updates);
    try std.testing.expect(!host(client).view.dirty);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates + 1, host(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expect(!host(client).view.dirty);
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);

    const presented_version = client.model.version();
    const presented_updates = host(client).presenter.pending_updates;
    const same_name = try encodePaneCwd_module(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .cwd = "/other/telar",
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(same_name));

    try std.testing.expectEqualStrings(
        "/other/telar",
        client.model.workspace.findPane(TestHarness.bootstrap_pane).?.cwdSlice(),
    );
    try std.testing.expectEqualDeep(presented_version, client.model.version());
    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(presented_updates, host(client).presenter.pending_updates);

    const stale = try encodePaneCwd_module(&payload, .{
        .pane_id = @enumFromInt(99),
        .cwd = "/missing",
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(stale));
    try std.testing.expectEqualDeep(presented_version, client.model.version());
}

test "pane foreground and focus update automatic tab labels through presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try harness.addInactiveTab(@enumFromInt(2), @enumFromInt(20));
    const version = client.model.version();
    const pending_updates = host(client).presenter.pending_updates;

    var payload: [128]u8 = undefined;
    const foreground = try encodePaneForeground_module(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .name = "Claude Code",
    });
    _ = try server_messages.handleServerMessage(
        client,
        try decodeServer_module(foreground),
    );

    try std.testing.expectEqualStrings(
        "Claude Code",
        client.model.workspace.findPane(TestHarness.bootstrap_pane).?.foregroundName(),
    );
    try std.testing.expectEqual(version.pane_metadata + 1, client.model.version().pane_metadata);
    try std.testing.expectEqual(version.pane_foreground + 1, client.model.version().pane_foreground);
    try std.testing.expectEqual(pending_updates, host(client).presenter.pending_updates);
    try std.testing.expect(!host(client).view.dirty);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try expectBootstrapTab(&harness, "shell", .app_terminal);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates + 1, host(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expect(!host(client).view.dirty);
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);
    try expectBootstrapTab(&harness, "Claude Code", .provider_claude);

    const presented_version = client.model.version();
    const presented_updates = host(client).presenter.pending_updates;
    _ = try server_messages.handleServerMessage(
        client,
        try decodeServer_module(foreground),
    );
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(presented_version, client.model.version());
    try std.testing.expectEqual(presented_updates, host(client).presenter.pending_updates);

    const second_pane: PaneIdType = @enumFromInt(11);
    _ = try client.model.commitPaneSplit(.{
        .split = .{
            .target_pane = TestHarness.bootstrap_pane,
            .location = TestHarness.bootstrap_location,
            .axis = .horizontal,
            .area = host(client).view.workbench(),
        },
        .new_pane = second_pane,
    });
    const next_foreground = try encodePaneForeground_module(&payload, .{ .pane_id = second_pane, .name = "git" });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(next_foreground));
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    try expectBootstrapTab(&harness, "git", .app_git);

    try std.testing.expect(client.model.focusPane(.{
        .target = .{ .pane_id = TestHarness.bootstrap_pane },
        .area = host(client).view.workbench(),
    }) != null);
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    try expectBootstrapTab(&harness, "Claude Code", .provider_claude);
}

fn expectBootstrapTab(harness: *const TestHarness, name: []const u8, icon: IconType) !void {
    const terminal = host(harness.client);
    const screen = &terminal.presenter.screen;
    for (terminal.view.hits.registered()) |entry| {
        if (entry.action != .select_tab or entry.action.select_tab != TestHarness.bootstrap_location.tab_id) {
            continue;
        }

        var storage: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        for (entry.rect.x..entry.rect.x + entry.rect.w) |column| {
            const cell = screen.front.cells[@as(usize, entry.rect.y) * screen.front.w + column];
            try writer.writeAll(cell.text());
        }

        var expected_storage: [128]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_storage, " 1:{s} {s} ", .{ icon.unicodeGlyph(), name });
        try std.testing.expectEqualStrings(expected, writer.buffered());
        return;
    }

    return error.TestTabMissing;
}

test "close pane request waits for the authoritative exit before committing" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const closing_pane: PaneIdType = @enumFromInt(11);
    const split = try client.model.commitPaneSplit(.{
        .split = .{
            .target_pane = TestHarness.bootstrap_pane,
            .location = TestHarness.bootstrap_location,
            .axis = .horizontal,
            .area = host(client).view.workbench(),
        },
        .new_pane = closing_pane,
    });
    try std.testing.expect(split.change == .changed);
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    _ = client.model.syncReportedPaneFocus().?;
    try std.testing.expectEqual(closing_pane, client.model.beginPanePaste().?.pane_id);
    try host(client).graphics_store.applyImage(.{
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
    const pending_updates_before_request = host(client).presenter.pending_updates;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .close_pane);

    try std.testing.expect(client.model.workspace.findPane(closing_pane) != null);
    try std.testing.expectEqualDeep(version_before_request, client.model.version());
    try std.testing.expectEqual(pending_updates_before_request, host(client).presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 1), client.request_lifecycle.tracker.count);

    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const requested = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(requested == .close_pane);
    try std.testing.expectEqual(closing_pane, requested.close_pane.pane_id);
    try std.testing.expect(requested.close_pane.request_id != .none);
    try std.testing.expect(!client.model.enterCopyMode());

    var payload: [128]u8 = undefined;
    const exited = try encodePaneExited_module(&payload, .{
        .pane_id = closing_pane,
        .kind = .exited,
        .value = 0,
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(exited));

    try std.testing.expect(client.model.workspace.findPane(closing_pane) == null);
    try std.testing.expectEqual(version_before_request.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_request, host(client).presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(!client.model.panePasteActive());
    try std.testing.expectEqual(@as(?PaneIdType, TestHarness.bootstrap_pane), support.reportedPaneId(client));
    try std.testing.expect(!host(client).graphics_store.hasPaneGraphics(closing_pane));
    try std.testing.expect(!client.notification_scheduler.pending);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_request + 1, host(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);
    const committed_version = client.model.version();
    const pending_updates_after_commit = host(client).presenter.pending_updates;

    const repeated = try pane_closures.applyExit(client, (try decodeServer_module(exited)).pane_exited);
    try std.testing.expect(repeated == .stale);
    try std.testing.expectEqual(closing_pane, repeated.stale.pane_id);
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(committed_version, client.model.version());
    try std.testing.expectEqual(pending_updates_after_commit, host(client).presenter.pending_updates);
}

test "an unrequested pane exit removes the pane silently" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    try std.testing.expect(client.model.enterCopyMode());
    try host(client).graphics_store.applyImage(.{
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
    const pending_updates_before_exit = host(client).presenter.pending_updates;

    var payload: [128]u8 = undefined;
    const exited = try encodePaneExited_module(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .kind = .exited,
        .value = 0,
    });
    const transition = try pane_closures.applyExit(client, (try decodeServer_module(exited)).pane_exited);
    try std.testing.expect(transition == .retired);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, transition.retired.pane_id);
    try std.testing.expect(transition.retired.active);
    try std.testing.expect(transition.retired.tab_empty);
    try harness.settle();

    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane) == null);
    try std.testing.expectEqual(version_before_exit.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_exit, host(client).presenter.pending_updates);
    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expectEqual(@as(?PaneIdType, null), support.reportedPaneId(client));
    try std.testing.expect(!host(client).graphics_store.hasPaneGraphics(TestHarness.bootstrap_pane));
    try std.testing.expect(!client.notification_scheduler.pending);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_exit + 1, host(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);
}

test "an inactive pane exit retires only inactive state" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const inactive_pane: PaneIdType = @enumFromInt(20);
    const inactive = try harness.addInactiveTab(@enumFromInt(2), inactive_pane);
    try host(client).graphics_store.applyImage(.{
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
    const pending_updates_before_exit = host(client).presenter.pending_updates;

    var payload: [128]u8 = undefined;
    const exited = try encodePaneExited_module(&payload, .{
        .pane_id = inactive_pane,
        .kind = .signaled,
        .value = 15,
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(exited));

    try std.testing.expect(client.model.workspace.findPane(inactive_pane) == null);
    try std.testing.expectEqualDeep(version_before_exit, client.model.version());
    try std.testing.expectEqual(pending_updates_before_exit, host(client).presenter.pending_updates);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqual(@as(?PaneIdType, TestHarness.bootstrap_pane), support.reportedPaneId(client));
    try std.testing.expect(!host(client).graphics_store.hasPaneGraphics(inactive_pane));
    try std.testing.expect(client.request_lifecycle.tracker.take(@enumFromInt(4)) == null);
    try std.testing.expect(client.request_lifecycle.tracker.take(@enumFromInt(5)).? == .ignored);
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_exit + 1, host(client).presenter.pending_updates);
}
