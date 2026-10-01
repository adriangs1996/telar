//! The shared client's runtime transport: the outbox and its single write,
//! the runtime read, request correlation, the bootstrap and the first open,
//! and the client layout it restores and reports.
const keyinput = @import("keyinput");
const data = @import("model");
const client_module = @import("telar-client");
const core = @import("telar-core");
const keys = @import("keys.zig");
const ClientHarness = @import("ClientHarness.zig");
const pacing = @import("pacing");
const std = @import("std");
const fixtures = @import("fixtures.zig");

test "host input arriving while no tab exists is dropped, not a crash" {
    // The workspace-handoff window: `tabs.deinit()` has run and the new
    // pane has not been confirmed. A keystroke here used to null-unwrap.
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();

    try keys.pressKey(harness.client, .plain(.{ .char = keyinput.Char.init("x") }));
    try std.testing.expectEqual(@as(usize, 0), harness.client.model.to_runtime.len);
}

test "host input reads pause at outbox capacity and resume with one token" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    try client.model.to_runtime.push(
        .{
            .detach_pane = .{
                .pane_id = ClientHarness.bootstrap_pane,
            },
        },
    );
    try harness.deliverHostEffects();
    while (client.model.to_runtime.hasCapacity()) {
        try client.model.to_runtime.push(.{ .detach_pane = .{ .pane_id = ClientHarness.bootstrap_pane } });
    }

    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.availableCapacity());

    switch (try harness.receiveClient()) {
        .sent => |result| try client_module.runtime_io.completeRuntimeSend(client, result),
        else => return error.UnexpectedEvent,
    }

    try std.testing.expect(client.model.to_host.resume_input);
    try harness.deliverHostEffects();
    try std.testing.expectEqual(data.outbox_support.capacity - 1, @as(usize, client.model.to_runtime.len));
    try std.testing.expect(client.model.to_runtime.inFlight());
    try std.testing.expectEqual(@as(usize, 1), client.model.to_runtime.availableCapacity());
}

test "runtime reads own one token and do not rearm after shutdown" {
    const io = std.testing.io;
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;

    try client_module.runtime_io.startRuntimeRead(client);
    try client_module.runtime_io.startRuntimeRead(client);
    try std.testing.expect(client.runtime_transport.receive_pending);

    var payload: [64]u8 = undefined;
    const metrics = try core.encodeSystemMetrics(&payload, .{
        .revision = 1,
        .cpu_percent = 50,
        .memory_used_decigib = 10,
        .has_battery = false,
        .battery_percent = 0,
        .cpu_count = 4,
        .memory_total_decigib = 160,
    });
    try harness.peer.send(io, metrics);
    switch (try harness.receiveClient()) {
        .server => |result| try std.testing.expectEqual(
            @as(?u8, null),
            try client_module.runtime_io.receiveRuntime(client, result),
        ),
        else => return error.UnexpectedEvent,
    }

    try std.testing.expect(client.runtime_transport.receive_pending);
    try std.testing.expectEqual(@as(u64, 1), client.model.system_metrics.?.runtime_revision);

    try harness.peer.send(io, try core.encodeRuntimeStopping(&payload));
    switch (try harness.receiveClient()) {
        .server => |result| try std.testing.expectEqual(
            @as(?u8, 0),
            try client_module.runtime_io.receiveRuntime(client, result),
        ),
        else => return error.UnexpectedEvent,
    }

    try std.testing.expect(!client.runtime_transport.receive_pending);

    client.runtime_transport.receive_pending = true;
    try std.testing.expectError(
        error.RuntimeReadFailed,
        client_module.runtime_io.receiveRuntime(client, error.RuntimeReadFailed),
    );
    try std.testing.expect(!client.runtime_transport.receive_pending);
}

test "graphics credits remain owned until the outbox accepts them" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const pane_id: core.PaneId = @enumFromInt(7);
    // A pane whose four-byte image the host released, as the store holds it
    // once a newer snapshot replaced the image.
    var credits: PendingCredit = .{
        .credit = .{
            .pane_id = pane_id,
            .bytes = 4,
        },
    };
    client.graphics = credits.port();
    while (client.model.to_runtime.hasCapacity()) {
        try client.model.to_runtime.push(.{ .detach_pane = .{ .pane_id = pane_id } });
    }

    try harness.deliverHostEffects();
    try std.testing.expectEqual(@as(usize, 4), client.graphics.peekCredit().?.bytes);
    try std.testing.expect(client.model.to_runtime.inFlight());

    switch (try harness.receiveClient()) {
        .sent => |result| try client_module.runtime_io.completeRuntimeSend(client, result),
        else => return error.UnexpectedEvent,
    }

    try harness.deliverHostEffects();
    try std.testing.expect(client.graphics.peekCredit() == null);
    try std.testing.expectEqual(data.outbox_support.capacity, @as(usize, client.model.to_runtime.len));
    try std.testing.expect(client.model.to_runtime.inFlight());
}

test "runtime write errors release the outbound token" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    try client.model.to_runtime.push(.{
        .detach_pane = .{ .pane_id = ClientHarness.bootstrap_pane },
    });
    _ = (try client.model.to_runtime.beginSend(client.runtime_transport.send_buffer)).?;

    try std.testing.expectError(
        error.RuntimeWriteFailed,
        client_module.runtime_io.completeRuntimeSend(client, error.RuntimeWriteFailed),
    );
    try std.testing.expect(!client.model.to_runtime.inFlight());
    try std.testing.expectEqual(@as(u8, 1), client.model.to_runtime.len);
}

test "request delivery rolls correlation back when transport is full" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    while (client.model.to_runtime.hasCapacity()) {
        try client.model.to_runtime.push(.{
            .detach_pane = .{ .pane_id = ClientHarness.bootstrap_pane },
        });
    }

    const request_id = try client.model.request_lifecycle.nextId();

    try std.testing.expectError(error.ClientOutboxFull, client_module.runtime_io.sendRuntimeRequest(&client.model, .{
        .registration = .{
            .request_id = request_id,
            .continuation = .{ .tab_snapshot = ClientHarness.bootstrap_location },
        },
        .message = .{ .request_tab_snapshot = .{
            .request_id = request_id,
            .location = ClientHarness.bootstrap_location,
        } },
    }));
    try std.testing.expect(client.model.request_lifecycle.tracker.take(request_id) == null);
    try std.testing.expect(client.model.request_lifecycle.tracker.isEmpty());
}

test "client startup waits for runtime layout before its initial open" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.options.arguments = &.{"/bin/sh"};
    const expected_size = data.multiplexer.rectSize(client.geometry().area).?;
    const colors: core.TerminalColors = .{
        .foreground = .{ 255, 255, 255 },
        .background = .{ 16, 16, 16 },
    };

    // What an adapter queues once its host is ready, before the runtime
    // has answered anything.
    client.model.startup.phase = .opening;
    try client.model.to_runtime.pushBootstrap(
        .{
            .graphics_shared = client_module.supportsSharedMemory(),
            .client_identity = client.client_identity,
            .terminal_colors = colors,
        },
        client.model.host.host_capabilities.frame_interval_ns,
    );

    try std.testing.expect(client.model.request_lifecycle.tracker.isEmpty());
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const configure = try harness.nextClientMessage(&buffer);
    try std.testing.expect(configure == .configure_graphics);
    try std.testing.expectEqual(client_module.supportsSharedMemory(), configure.configure_graphics.shared);
    const configured_colors = try harness.nextClientMessage(&buffer);
    try std.testing.expect(configured_colors == .configure_terminal_colors);
    try std.testing.expectEqualDeep(colors, configured_colors.configure_terminal_colors);
    const frame_interval = try harness.nextClientMessage(&buffer);
    try std.testing.expectEqual(pacing.pace.default_interval, frame_interval.configure_frame_interval.interval_ns);
    const runtime_state = try harness.nextClientMessage(&buffer);
    try std.testing.expect(runtime_state == .request_runtime_state);
    try std.testing.expectEqual(client.client_identity, runtime_state.request_runtime_state.client_identity);
    try std.testing.expect(client.model.request_lifecycle.tracker.isEmpty());
    try std.testing.expectEqual(@as(u8, 0), client.model.to_runtime.len);

    const empty_layout = try core.encodeClientLayoutSnapshot(&buffer, .{ .restored = false });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(empty_layout));
    try harness.settle();

    try std.testing.expect(client.model.request_lifecycle.tracker.has(.initial_open));
    const open = try harness.nextClientMessage(&buffer);
    try std.testing.expect(open == .open_pane);
    try std.testing.expectEqual(client_module.initial_request_id, open.open_pane.request_id);
    try std.testing.expectEqualDeep(expected_size, open.open_pane.size);
    try std.testing.expectEqualStrings("/", open.open_pane.launch.?.cwd);
    var arguments = open.open_pane.launch.?.arguments();
    try std.testing.expectEqualStrings("/bin/sh", (try arguments.next()).?);
    try std.testing.expect((try arguments.next()) == null);
}

test "client startup validates geometry before request registration" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.model.startup.phase = .opening;

    // A window narrower than one cell leaves the workbench no column.
    client.model.host.host_size.cols = 0;

    var buffer: [256]u8 = undefined;
    const empty_layout = try core.encodeClientLayoutSnapshot(&buffer, .{ .restored = false });

    try std.testing.expectError(
        error.TerminalTooSmall,
        client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(empty_layout)),
    );

    try std.testing.expect(client.model.request_lifecycle.tracker.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "restored client layout controls the initial attach geometry" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(7) },
        .tab_id = @enumFromInt(9),
    };
    const pane_id: core.PaneId = @enumFromInt(44);
    const nodes = [_]core.ClientLayoutNode{.{ .pane = .{ .id = pane_id } }};
    const tabs = [_]core.ClientTabLayout{.{
        .location = location,
        .focused_pane = pane_id,
        .fullscreen = false,
        .workspace_active = true,
        .nodes = &nodes,
    }};
    const restored: core.ClientLayoutSnapshot = .{
        .restored = true,
        .sidebar_visible = true,
        .sidebar_width = 50,
        .workspace_list_collapsed = true,
        .active_tab = location,
        .tabs = &tabs,
    };
    var buffer: [core.max_client_layout_wire_bytes]u8 = undefined;
    const payload = try core.encodeClientLayoutSnapshot(&buffer, restored);

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(payload));
    try harness.settle();

    try std.testing.expect(client.model.sidebar_visible);
    try std.testing.expectEqual(@as(u16, 50), client.model.sidebar_width);
    try std.testing.expect(client.model.workspace_list_collapsed);
    try std.testing.expectEqual(pane_id, client.model.saved_layouts.find(location).?.pane_id);
    try std.testing.expectEqual(pane_id, client.model.navigation_history.find(location.workspace).?.pane_id);

    const open = try harness.nextClientMessage(&buffer);
    try std.testing.expect(open == .open_pane);
    try std.testing.expect(open.open_pane.target == .pane);
    try std.testing.expectEqual(pane_id, open.open_pane.target.pane);
    try std.testing.expect(open.open_pane.launch == null);
    try std.testing.expectEqualDeep(
        data.multiplexer.rectSize(client.geometry().area).?,
        open.open_pane.size,
    );

    const duplicate_payload = try core.encodeClientLayoutSnapshot(&buffer, restored);
    try std.testing.expectError(
        error.DuplicateClientLayoutSnapshot,
        client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(duplicate_payload)),
    );
}

test "sidebar preferences survive when retained pane layouts become stale" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.options.arguments = &.{"/bin/sh"};
    var buffer: [core.max_client_layout_wire_bytes]u8 = undefined;
    const payload = try core.encodeClientLayoutSnapshot(&buffer, .{
        .restored = true,
        .sidebar_visible = true,
        .sidebar_width = 51,
        .workspace_list_collapsed = true,
    });

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(payload));
    try harness.settle();

    try std.testing.expectEqual(@as(u16, 51), client.model.sidebar_width);
    try std.testing.expect(client.model.workspace_list_collapsed);
    const open = try harness.nextClientMessage(&buffer);
    try std.testing.expect(open == .open_pane);
    try std.testing.expect(open.open_pane.target == .default);
    try std.testing.expect(open.open_pane.launch != null);
}

test "bootstrap answers the initial open with both snapshot requests" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();

    try std.testing.expectEqual(@as(usize, 1), harness.client.model.tabs.count);
    const pane = harness.client.model.panes.find(ClientHarness.bootstrap_pane).?;
    try std.testing.expect(pane.attached);
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, fixtures.reportedPaneId(harness.client));
    try std.testing.expectEqual(@as(u64, 1), harness.client.model.version().workspace);
    try std.testing.expectEqual(@as(u64, 1), harness.client.model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), harness.client.model.version().active_tab);
    try std.testing.expectEqual(@as(u64, 1), harness.client.model.version().panes);
    try std.testing.expectEqualDeep(
        harness.client.model.version(),
        harness.client.presentation.prepared.model,
    );
}

test "client layout observation sends one canonical workspace update" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.tabs.snapshot_loaded[client.model.tabs.active] = true;
    try client.model.client_layouts.markSnapshotReceived();
    try std.testing.expect(data.sidebar.restoreLayout(&client.model, true, 53) != null);
    try std.testing.expect(data.workspace_list.setCollapsed(&client.model, true) != null);

    try client_module.client_layout.synchronizeClientLayout(&client.model);
    try std.testing.expectEqual(@as(u8, 1), client.model.to_runtime.len);
    try client_module.client_layout.synchronizeClientLayout(&client.model);
    try std.testing.expectEqual(@as(u8, 1), client.model.to_runtime.len);
    try harness.settle();

    var buffer: [core.max_client_layout_wire_bytes]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .update_client_layout);
    const update = message.update_client_layout;
    try std.testing.expect(update.sidebar_visible);
    try std.testing.expectEqual(@as(u16, 53), update.sidebar_width);
    try std.testing.expect(update.workspace_list_collapsed);
    try std.testing.expectEqualDeep(ClientHarness.bootstrap_location, update.active_tab);
    try std.testing.expectEqual(@as(u16, 1), update.tab_count);
    var tabs = update.tabs();
    const tab = (try tabs.next()).?;
    try std.testing.expectEqualDeep(ClientHarness.bootstrap_location, tab.location);
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, tab.focused_pane);
    try std.testing.expect(tab.workspace_active);
    var nodes = tab.nodes();
    const node = (try nodes.next()).?;
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, node.pane.id);
    try std.testing.expect(try nodes.next() == null);
    try std.testing.expect(try tabs.next() == null);
}

// Presses one key through the keymap, as a window delivers it.
/// A graphics store holding one credit the host released, standing in for
/// the harness's store, which never releases any.
const PendingCredit = struct {
    credit: ?client_module.GraphicsCredit,

    fn port(self: *PendingCredit) client_module.GraphicsRetention {
        return .{
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

    fn from(context: *anyopaque) *PendingCredit {
        return @ptrCast(@alignCast(context));
    }

    fn apply(_: *anyopaque, _: data.PaneGraphicsCommand) !void {}

    fn clearPane(_: *anyopaque, _: core.PaneId) void {}

    fn setVisible(_: *anyopaque, _: core.PaneId, _: bool) !void {}

    fn visible(_: *anyopaque, _: core.PaneId) bool {
        return true;
    }

    fn hasGraphics(_: *anyopaque, _: core.PaneId) bool {
        return false;
    }

    fn ingress(_: *anyopaque) u64 {
        return 0;
    }

    fn peekCredit(context: *anyopaque) ?client_module.GraphicsCredit {
        return from(context).credit;
    }

    fn consumeCredit(context: *anyopaque, credit: client_module.GraphicsCredit) void {
        const self = from(context);
        std.debug.assert(self.credit.?.pane_id == credit.pane_id);
        self.credit = null;
    }
};
