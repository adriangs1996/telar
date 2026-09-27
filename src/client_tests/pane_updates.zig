//! Pane updates through the concrete client, its model and real transport:
//! frames, metadata, foreground names and pane exits.
const cellgrid = @import("cellgrid");
const data = @import("model");
const core = @import("telar-core");
const client_module = @import("telar-client");
const std = @import("std");
const ClientHarness = @import("ClientHarness.zig");
const fixtures = @import("fixtures.zig");

/// Panes a test gives graphics at once.
const probe_capacity = 4;

test "a patch against an unknown base requests a fresh snapshot" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version = client.model.version();
    const observed = client.presentation.observed;
    const frames = client.telemetry.metrics.frames;

    var payload: [512]u8 = undefined;
    const patch = try core.encodePaneFrame(&payload, .{
        .pane_id = ClientHarness.bootstrap_pane,
        .frame_id = 5,
        .base_frame_id = 4,
        .cols = 40,
        .rows = 10,
        .scroll = .{ .total_rows = 10, .offset = 0 },
        .spans = &.{},
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(patch));
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqualDeep(observed, client.presentation.observed);
    try std.testing.expect(!observePresentation(&harness));
    if (comptime core.enabled) {
        try std.testing.expectEqual(frames, client.telemetry.metrics.frames);
    }

    try harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .request_snapshot);
    try std.testing.expectEqual(@as(u64, 0), message.request_snapshot.known_frame_id);

    // A full snapshot must carry exactly one span covering the whole grid.
    const blank: cellgrid.Cell = .{};
    const cells: [4]cellgrid.Cell = @splat(blank);
    try harness.graphics.setPaneVisible(ClientHarness.bootstrap_pane, false);
    const observed_before_snapshot = client.presentation.observed;
    const snapshot = try core.encodePaneFrame(&payload, .{
        .pane_id = ClientHarness.bootstrap_pane,
        .frame_id = 5,
        .base_frame_id = 0,
        .cols = 2,
        .rows = 2,
        .scroll = .{ .total_rows = 2, .offset = 0 },
        .spans = &.{.{ .start = 0, .cells = &cells }},
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(snapshot));
    const pane = client.model.panes.find(ClientHarness.bootstrap_pane).?;

    try std.testing.expectEqual(@as(u64, 5), pane.applied_frame_id);
    try std.testing.expectEqual(@as(u64, 5), pane.pending_frame_id);
    try std.testing.expectEqual(version.frame + 1, client.model.version().frame);
    try std.testing.expectEqualDeep(observed_before_snapshot, client.presentation.observed);
    try std.testing.expect(client.graphics.paneVisible(ClientHarness.bootstrap_pane));
    if (comptime core.enabled) {
        try std.testing.expectEqual(frames + 1, client.telemetry.metrics.frames);
        try std.testing.expectEqual(@as(u64, 1), client.telemetry.metrics.snapshots);
        try std.testing.expectEqual(@as(u64, 1), client.telemetry.metrics.frame_spans);
        try std.testing.expectEqual(@as(u64, 4), client.telemetry.metrics.frame_cells);
    }

    const ack = try harness.nextClientMessage(&buffer);
    try std.testing.expect(ack == .frame_ack);
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, ack.frame_ack.pane_id);
    try std.testing.expectEqual(@as(u64, 5), ack.frame_ack.frame_id);
    try std.testing.expectEqual(@as(u64, 5), pane.pending_frame_id);
    try std.testing.expect(observePresentation(&harness));
    try harness.settleModelPresentation();
    try std.testing.expectEqual(@as(u64, 0), pane.pending_frame_id);
    try harness.settle();
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "a frame made stale by detach has no state resources or presentation effects" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pane = client.model.panes.find(ClientHarness.bootstrap_pane).?;
    pane.attached = false;
    const version = client.model.version();
    const observed = client.presentation.observed;
    const graphics_visible = client.graphics.paneVisible(ClientHarness.bootstrap_pane);
    const frames = client.telemetry.metrics.frames;
    const cells = [_]cellgrid.Cell{.{}};
    var payload: [256]u8 = undefined;
    const snapshot = try core.encodePaneFrame(&payload, .{
        .pane_id = ClientHarness.bootstrap_pane,
        .frame_id = 8,
        .base_frame_id = 0,
        .cols = 1,
        .rows = 1,
        .scroll = .{ .total_rows = 1, .offset = 0 },
        .spans = &.{.{ .start = 0, .cells = &cells }},
    });

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(snapshot));

    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(@as(u64, 0), pane.applied_frame_id);
    try std.testing.expectEqual(@as(u64, 0), pane.pending_frame_id);
    try std.testing.expectEqual(graphics_visible, client.graphics.paneVisible(pane.id));
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
    if (comptime core.enabled) {
        try std.testing.expectEqual(frames, client.telemetry.metrics.frames);
    }

    try std.testing.expectEqualDeep(observed, client.presentation.observed);
    try std.testing.expect(!observePresentation(&harness));
}

test "a frame already sent before workspace departure is harmless during handoff" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.request_lifecycle.tracker = .{};

    const cells = [_]cellgrid.Cell{.{}};
    var payload: [256]u8 = undefined;
    const snapshot = try core.encodePaneFrame(&payload, .{
        .pane_id = ClientHarness.bootstrap_pane,
        .frame_id = 8,
        .base_frame_id = 0,
        .cols = 1,
        .rows = 1,
        .scroll = .{ .total_rows = 1, .offset = 0 },
        .spans = &.{.{ .start = 0, .cells = &cells }},
    });

    // The runtime writes this frame before it can observe the client's detach.
    try harness.peer.send(std.testing.io, snapshot);
    _ = try client_module.workspace_handoff.requestWorkspace(client, @enumFromInt(2));
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const detached = try harness.nextClientMessage(&buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, detached.detach_pane.pane_id);
    const opened = try harness.nextClientMessage(&buffer);
    try std.testing.expect(opened == .open_pane);
    try std.testing.expect(opened.open_pane.target == .workspace);
    try std.testing.expectEqual(@as(u64, 2), @intFromEnum(opened.open_pane.target.workspace));
    try std.testing.expect(client.model.workspace == null);
    const version = client.model.version();
    const observed = client.presentation.observed;
    const graphics_version = client.graphics.ingressVersion();
    const graphics_visible = client.graphics.paneVisible(ClientHarness.bootstrap_pane);
    const frames = client.telemetry.metrics.frames;

    try client_module.runtime_io.startRuntimeRead(client);
    try receiveRuntime(&harness);

    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expect(client.model.panes.find(ClientHarness.bootstrap_pane) == null);
    try std.testing.expectEqualDeep(observed, client.presentation.observed);
    try std.testing.expectEqual(graphics_version, client.graphics.ingressVersion());
    try std.testing.expectEqual(graphics_visible, client.graphics.paneVisible(ClientHarness.bootstrap_pane));
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
    if (comptime core.enabled) {
        try std.testing.expectEqual(frames, client.telemetry.metrics.frames);
    }

    const destination_pane: core.PaneId = @enumFromInt(20);
    const destination: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(2),
    };
    const arrived = try core.encodePaneOpened(&payload, .{
        .request_id = opened.open_pane.request_id,
        .pane_id = destination_pane,
        .location = destination,
        .created = false,
    });
    try harness.peer.send(std.testing.io, arrived);
    try receiveRuntime(&harness);

    try std.testing.expectEqualDeep(destination.workspace, client.model.workspace.?);
    try std.testing.expect(client.model.panes.find(ClientHarness.bootstrap_pane) == null);
    const pane = client.model.panes.find(destination_pane).?;
    try std.testing.expect(pane.attached);
    try harness.settle();
    const workspace_snapshot = try harness.nextClientMessage(&buffer);
    try std.testing.expect(workspace_snapshot == .request_workspace_snapshot);
    const tab_snapshot = try harness.nextClientMessage(&buffer);
    try std.testing.expect(tab_snapshot == .request_tab_snapshot);
    try std.testing.expectEqualDeep(destination, tab_snapshot.request_tab_snapshot.location);

    var destination_cells = [_]cellgrid.Cell{.{}};
    destination_cells[0].bytes[0] = 'N';
    const destination_snapshot = try core.encodePaneFrame(&payload, .{
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
    try receiveRuntime(&harness);

    try std.testing.expectEqual(@as(u64, 9), pane.applied_frame_id);
    try std.testing.expectEqual(@as(u64, 9), pane.pending_frame_id);
    try std.testing.expectEqualStrings("N", pane.buffer.cells[0].text());
    try std.testing.expectEqual(arrival_version.frame + 1, client.model.version().frame);
    if (comptime core.enabled) {
        try std.testing.expectEqual(frames + 1, client.telemetry.metrics.frames);
    }

    try harness.settle();
    const ack = try harness.nextClientMessage(&buffer);
    try std.testing.expect(ack == .frame_ack);
    try std.testing.expectEqual(destination_pane, ack.frame_ack.pane_id);
    try std.testing.expectEqual(@as(u64, 9), ack.frame_ack.frame_id);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "pane cwd commits before presenter-owned metadata projection" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version = client.model.version();
    const observed = client.presentation.observed;

    var payload: [128]u8 = undefined;
    const cwd = try core.encodePaneCwd(&payload, .{
        .pane_id = ClientHarness.bootstrap_pane,
        .cwd = "/work/telar",
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(cwd));

    try std.testing.expectEqualStrings(
        "/work/telar",
        client.model.panes.find(ClientHarness.bootstrap_pane).?.cwdSlice(),
    );
    try std.testing.expectEqual(version.pane_metadata + 1, client.model.version().pane_metadata);
    try std.testing.expectEqual(version.pane_foreground, client.model.version().pane_foreground);
    try std.testing.expectEqualDeep(observed, client.presentation.observed);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);

    try std.testing.expect(observePresentation(&harness));
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);

    const presented_version = client.model.version();
    const same_name = try core.encodePaneCwd(&payload, .{
        .pane_id = ClientHarness.bootstrap_pane,
        .cwd = "/other/telar",
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(same_name));

    try std.testing.expectEqualStrings(
        "/other/telar",
        client.model.panes.find(ClientHarness.bootstrap_pane).?.cwdSlice(),
    );
    try std.testing.expectEqualDeep(presented_version, client.model.version());
    try std.testing.expect(!observePresentation(&harness));

    const stale = try core.encodePaneCwd(&payload, .{
        .pane_id = @enumFromInt(99),
        .cwd = "/missing",
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(stale));
    try std.testing.expectEqualDeep(presented_version, client.model.version());
}

test "pane foreground and focus update automatic tab labels through presentation" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try harness.addInactiveTab(@enumFromInt(2), @enumFromInt(20));
    try expectBootstrapTab(&harness, "shell", .app_terminal);
    const version = client.model.version();
    const observed = client.presentation.observed;

    var payload: [128]u8 = undefined;
    const foreground = try core.encodePaneForeground(&payload, .{
        .pane_id = ClientHarness.bootstrap_pane,
        .name = "Claude Code",
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(foreground));

    try std.testing.expectEqualStrings(
        "Claude Code",
        client.model.panes.find(ClientHarness.bootstrap_pane).?.foregroundName(),
    );
    try std.testing.expectEqual(version.pane_metadata + 1, client.model.version().pane_metadata);
    try std.testing.expectEqual(version.pane_foreground + 1, client.model.version().pane_foreground);
    try std.testing.expectEqualDeep(observed, client.presentation.observed);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);

    try std.testing.expect(observePresentation(&harness));
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);
    try expectBootstrapTab(&harness, "Claude Code", .provider_claude);

    const presented_version = client.model.version();
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(foreground));

    try std.testing.expectEqualDeep(presented_version, client.model.version());
    try std.testing.expect(!observePresentation(&harness));

    const second_pane: core.PaneId = @enumFromInt(11);
    _ = try data.pane_split.commitSplit(&client.model, .{
        .split = .{
            .target_pane = ClientHarness.bootstrap_pane,
            .location = ClientHarness.bootstrap_location,
            .axis = .horizontal,
            .area = client.geometry().area,
        },
        .new_pane = second_pane,
    });
    const next_foreground = try core.encodePaneForeground(&payload, .{ .pane_id = second_pane, .name = "git" });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(next_foreground));
    try harness.settleModelPresentation();
    try expectBootstrapTab(&harness, "git", .app_git);

    try std.testing.expect(data.pane_focus.focusPane(&client.model, .{
        .target = .{ .pane_id = ClientHarness.bootstrap_pane },
        .area = client.geometry().area,
    }) != null);
    try harness.settleModelPresentation();
    try expectBootstrapTab(&harness, "Claude Code", .provider_claude);
}

test "close pane request waits for the authoritative exit before committing" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    var probe: GraphicsProbe = undefined;
    probe.install(client);
    client.model.request_lifecycle.tracker = .{};
    const closing_pane: core.PaneId = @enumFromInt(11);
    const split = try data.pane_split.commitSplit(&client.model, .{
        .split = .{
            .target_pane = ClientHarness.bootstrap_pane,
            .location = ClientHarness.bootstrap_location,
            .axis = .horizontal,
            .area = client.geometry().area,
        },
        .new_pane = closing_pane,
    });
    try std.testing.expect(split.change == .changed);
    try harness.settleModelPresentation();
    _ = data.pane_focus.syncReported(&client.model).?;
    try std.testing.expectEqual(closing_pane, data.pane_input.beginPaste(&client.model).?.pane_id);
    try applyTestingImage(client, closing_pane);
    const version_before_request = client.model.version();
    const observed_before_request = client.presentation.observed;

    _ = try client_module.actions.executeAction(client, .close_pane, .effect);

    try std.testing.expect(client.model.panes.find(closing_pane) != null);
    try std.testing.expectEqualDeep(version_before_request, client.model.version());
    try std.testing.expectEqualDeep(observed_before_request, client.presentation.observed);
    try std.testing.expectEqual(@as(usize, 1), client.model.request_lifecycle.tracker.count);

    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const requested = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(requested == .close_pane);
    try std.testing.expectEqual(closing_pane, requested.close_pane.pane_id);
    try std.testing.expect(requested.close_pane.request_id != .none);
    try std.testing.expect(!data.copy_mode.enter(&client.model));

    var payload: [128]u8 = undefined;
    const exited = try core.encodePaneExited(&payload, .{
        .pane_id = closing_pane,
        .kind = .exited,
        .value = 0,
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(exited));

    try std.testing.expect(client.model.panes.find(closing_pane) == null);
    try std.testing.expectEqual(version_before_request.panes + 1, client.model.version().panes);
    try std.testing.expectEqualDeep(observed_before_request, client.presentation.observed);
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expect(!data.copy_mode.isActive(&client.model));
    try std.testing.expect(!data.pane_input.pasteActive(&client.model));
    try std.testing.expectEqual(@as(?core.PaneId, ClientHarness.bootstrap_pane), fixtures.reportedPaneId(client));
    try std.testing.expect(!client.graphics.hasPaneGraphics(closing_pane));
    try std.testing.expect(!client.model.notification_scheduler.pending);

    try std.testing.expect(observePresentation(&harness));
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);
    const committed_version = client.model.version();

    _ = try client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .pane_exited = (try core.decodeServer(exited)).pane_exited,
        },
    );

    try std.testing.expectEqualDeep(committed_version, client.model.version());
    try std.testing.expect(!observePresentation(&harness));
}

test "an unrequested pane exit removes the pane silently" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    var probe: GraphicsProbe = undefined;
    probe.install(client);
    try std.testing.expect(data.copy_mode.enter(&client.model));
    try applyTestingImage(client, ClientHarness.bootstrap_pane);
    const version_before_exit = client.model.version();
    const observed_before_exit = client.presentation.observed;

    var payload: [128]u8 = undefined;
    const exited = try core.encodePaneExited(&payload, .{
        .pane_id = ClientHarness.bootstrap_pane,
        .kind = .exited,
        .value = 0,
    });
    _ = try client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .pane_exited = (try core.decodeServer(exited)).pane_exited,
        },
    );

    try std.testing.expectEqualDeep(observed_before_exit, client.presentation.observed);

    // The harness presents while it settles, so the observation comes first.
    try std.testing.expect(observePresentation(&harness));
    try harness.settle();

    try std.testing.expect(client.model.panes.find(ClientHarness.bootstrap_pane) == null);
    try std.testing.expectEqual(version_before_exit.panes + 1, client.model.version().panes);
    try std.testing.expect(!data.copy_mode.isActive(&client.model));
    try std.testing.expectEqual(@as(?core.PaneId, null), fixtures.reportedPaneId(client));
    try std.testing.expect(!client.graphics.hasPaneGraphics(ClientHarness.bootstrap_pane));
    try std.testing.expect(!client.model.notification_scheduler.pending);

    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.prepared.model);
}

test "an inactive pane exit retires only inactive state" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    var probe: GraphicsProbe = undefined;
    probe.install(client);
    client.model.request_lifecycle.tracker = .{};
    const inactive_pane: core.PaneId = @enumFromInt(20);
    const inactive = try harness.addInactiveTab(@enumFromInt(2), inactive_pane);
    try applyTestingImage(client, inactive_pane);
    try client.model.request_lifecycle.tracker.add(@enumFromInt(4), .{ .close_pane = .{
        .pane_id = inactive_pane,
        .location = inactive,
    } });
    try client.model.request_lifecycle.tracker.add(@enumFromInt(5), .{ .attach_pane = .{
        .pane_id = inactive_pane,
        .location = inactive,
    } });
    const version_before_exit = client.model.version();
    const observed_before_exit = client.presentation.observed;

    var payload: [128]u8 = undefined;
    const exited = try core.encodePaneExited(&payload, .{
        .pane_id = inactive_pane,
        .kind = .signaled,
        .value = 15,
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(exited));

    try std.testing.expect(client.model.panes.find(inactive_pane) == null);
    try std.testing.expectEqualDeep(version_before_exit, client.model.version());
    try std.testing.expectEqualDeep(observed_before_exit, client.presentation.observed);
    try std.testing.expectEqualDeep(ClientHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqual(@as(?core.PaneId, ClientHarness.bootstrap_pane), fixtures.reportedPaneId(client));
    try std.testing.expect(!client.graphics.hasPaneGraphics(inactive_pane));
    try std.testing.expect(client.model.request_lifecycle.tracker.take(@enumFromInt(4)) == null);
    try std.testing.expect(client.model.request_lifecycle.tracker.take(@enumFromInt(5)).? == .ignored);
    try std.testing.expectEqual(@as(usize, 0), client.model.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);

    try std.testing.expect(observePresentation(&harness));
}

// Observes the model as a window does after an event, as `ClientHarness.present`
// does before it prepares, and reports whether a presentation is due.
fn observePresentation(harness: *ClientHarness) bool {
    const client = harness.client;
    const projection = client_module.capture(&client.model, .{ .geometry = data.workbench.region(&client.model) });
    _ = client.presentation.observe(.{
        .model = projection.version,
        .presentation_ingress = projection.presentation_ingress,
        .geometry_revision = projection.geometry.revision,
    });

    return client.presentation.needsPreparation();
}

// Receives the next runtime read and hands it to the client, as the event
// loop does with a `.server` event.
fn receiveRuntime(harness: *ClientHarness) !void {
    switch (try harness.receiveClient()) {
        .server => |result| try std.testing.expectEqual(
            @as(?u8, null),
            try client_module.runtime_io.receiveRuntime(harness.client, result),
        ),
        else => return error.UnexpectedEvent,
    }
}

// The name and mark the bootstrap tab shows while it follows its focused
// foreground application.
fn expectBootstrapTab(harness: *const ClientHarness, name: []const u8, icon: data.icons.Icon) !void {
    const model = &harness.client.model;
    const slot = model.tabs.find(ClientHarness.bootstrap_location.tab_id) orelse return error.TestTabMissing;

    try std.testing.expectEqualStrings(name, data.tab_label.text(model, slot));
    try std.testing.expectEqual(@as(?data.icons.Icon, icon), data.tab_label.icon(model, slot));
}

// Gives `pane_id` one retained image through the client's graphics port.
fn applyTestingImage(client: *client_module.Client, pane_id: core.PaneId) !void {
    try client.graphics.apply(.{
        .image = .{
            .pane_id = pane_id,
            .revision = 1,
            .image = .{
                .key = .{ .image_id = 1, .generation = 1 },
                .format = .rgb,
                .width = 1,
                .height = 1,
                .byte_len = 3,
            },
        },
    });
}

/// Wraps the harness's graphics store to remember which panes hold images,
/// so a test sees the client clear a retired pane's graphics. Everything
/// else goes to the wrapped store.
const GraphicsProbe = struct {
    inner: client_module.GraphicsRetention,
    panes: [probe_capacity]core.PaneId = undefined,
    count: usize = 0,

    fn install(self: *GraphicsProbe, client: *client_module.Client) void {
        self.* = .{ .inner = client.graphics };
        client.graphics = .{
            .context = self,
            .apply_fn = apply,
            .clear_pane_fn = clearPane,
            .set_pane_visible_fn = setVisible,
            .pane_visible_fn = visible,
            .has_pane_graphics_fn = hasGraphics,
            .ingress_version_fn = ingress,
            .peek_credit_fn = peekCredit,
            .consume_credit_fn = consumeCredit,
        };
    }

    fn from(context: *anyopaque) *GraphicsProbe {
        return @ptrCast(@alignCast(context));
    }

    fn apply(context: *anyopaque, command: data.PaneGraphicsCommand) !void {
        const self = from(context);
        try self.inner.apply(command);
        if (hasGraphics(context, command.paneId())) {
            return;
        }

        if (self.count == self.panes.len) {
            return error.TooManyProbedPanes;
        }

        self.panes[self.count] = command.paneId();
        self.count += 1;
    }

    fn clearPane(context: *anyopaque, pane_id: core.PaneId) void {
        const self = from(context);
        self.inner.clearPane(pane_id);
        for (self.panes[0..self.count], 0..) |pane, index| {
            if (pane == pane_id) {
                self.panes[index] = self.panes[self.count - 1];
                self.count -= 1;
                return;
            }
        }
    }

    fn setVisible(context: *anyopaque, pane_id: core.PaneId, value: bool) !void {
        try from(context).inner.setPaneVisible(pane_id, value);
    }

    fn visible(context: *anyopaque, pane_id: core.PaneId) bool {
        return from(context).inner.paneVisible(pane_id);
    }

    fn hasGraphics(context: *anyopaque, pane_id: core.PaneId) bool {
        const self = from(context);
        for (self.panes[0..self.count]) |pane| {
            if (pane == pane_id) {
                return true;
            }
        }

        return false;
    }

    fn ingress(context: *anyopaque) u64 {
        return from(context).inner.ingressVersion();
    }

    fn peekCredit(context: *anyopaque) ?client_module.GraphicsCredit {
        return from(context).inner.peekCredit();
    }

    fn consumeCredit(context: *anyopaque, credit: client_module.GraphicsCredit) void {
        from(context).inner.consumeCredit(credit);
    }
};
