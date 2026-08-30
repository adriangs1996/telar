//! Substituted-platform tests for the Client: a real Client over a
//! socketpair standing in for the runtime socket, a pipe for the tty's
//! read handle, and a discarding writer for the host terminal.

const std = @import("std");
const core = @import("telar-core");
const input_capability = @import("../input/root.zig");
const lua_config = @import("../config/root.zig");
const widgets = @import("../widgets/root.zig");
const workspace_capability = @import("../workspace/root.zig");
const keybind = input_capability.keybind;

const Io = std.Io;
const File = Io.File;
const schema = core.schema;

const Client = @import("client.zig");
const InputHandler = @import("input_handler.zig");
const client_outbox = @import("outbox.zig");
const server_messages = @import("server_messages.zig");
const tab_attachments = @import("tab_attachments.zig");
const InputChunk = Client.InputChunk;
const initial_request_id = Client.initial_request_id;

// ---------------------------------------------------------------------------
// Test harness: a real Client over substituted platform dependencies — a
// socketpair instead of the runtime socket, a pipe instead of the tty's read
// handle, and a discarding writer instead of the host terminal.

const TestHarness = struct {
    connection: core.transport.SocketChannel,
    peer: core.transport.SocketChannel,
    input_read: File,
    input_write: File,
    sink: Io.Writer.Discarding,
    client: *Client,

    fn init(harness: *TestHarness) !void {
        var sockets: [2]std.c.fd_t = undefined;
        if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets) != 0)
            return error.SocketPairFailed;
        harness.connection = .init(.{ .socket = .{
            .handle = sockets[0],
            .address = .{ .ip4 = .loopback(0) },
        } });
        harness.peer = .init(.{ .socket = .{
            .handle = sockets[1],
            .address = .{ .ip4 = .loopback(0) },
        } });
        var pipe_fds: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&pipe_fds) != 0) return error.PipeFailed;
        harness.input_read = .{ .handle = pipe_fds[0], .flags = .{ .nonblocking = false } };
        harness.input_write = .{ .handle = pipe_fds[1], .flags = .{ .nonblocking = false } };
        harness.sink = .init(&.{});
        harness.client = try Client.init(.{
            .gpa = std.testing.allocator,
            .io = std.testing.io,
            .connection = &harness.connection,
            .input_file = harness.input_read,
            .writer = &harness.sink.writer,
            .host_size = .{ .cols = 80, .rows = 24, .cell_width_px = 0, .cell_height_px = 0 },
            .options = .{ .arguments = &.{}, .cwd = "/", .endpoint = "" },
        });
    }

    fn deinit(harness: *TestHarness) void {
        const io = std.testing.io;
        // EOF unblocks a pending input read so task cancellation never has
        // to wait on the pipe.
        harness.input_write.close(io);
        harness.client.deinit();
        harness.peer.deinit(io);
        harness.connection.deinit(io);
        harness.input_read.close(io);
    }

    /// Drives the real dispatch until the outbox is drained, so a test
    /// observes exactly what the runtime peer would receive.
    fn settle(harness: *TestHarness) !void {
        while (harness.client.outbox.inFlight() or harness.client.outbox.len != 0) {
            switch (try harness.client.select.await()) {
                .sent => |result| try harness.client.handleSentEvent(result),
                .draw => |result| try harness.client.handleDrawEvent(result),
                .sidebar_animation_tick => |result| try harness.client.handleSidebarAnimationEvent(result),
                .notification_tick => |result| try harness.client.handleNotificationTickEvent(result),
                else => return error.UnexpectedEvent,
            }
        }
    }

    fn settleModelPresentation(harness: *TestHarness) !void {
        const target = harness.client.model.version();
        while (!std.meta.eql(harness.client.presenter.presented_model_version, target)) {
            switch (try harness.client.select.await()) {
                .draw => |result| try harness.client.handleDrawEvent(result),
                .sent => |result| try harness.client.handleSentEvent(result),
                .media_tick => |result| try harness.client.handleMediaTickEvent(result),
                .sidebar_animation_tick => |result| try harness.client.handleSidebarAnimationEvent(result),
                .notification_tick => |result| try harness.client.handleNotificationTickEvent(result),
                else => return error.UnexpectedEvent,
            }
        }
    }

    /// Receives the next message the client sent to the runtime.
    fn nextClientMessage(harness: *TestHarness, buffer: []u8) !schema.ClientMessage {
        const payload = try harness.peer.receive(std.testing.io, buffer);
        return schema.decodeClient(payload);
    }

    fn nextAttachmentRequest(harness: *TestHarness, pane_id: schema.PaneId, buffer: []u8) !schema.RequestId {
        while (true) {
            switch (try harness.nextClientMessage(buffer)) {
                .open_pane => |open| {
                    if (open.target == .pane and open.target.pane == pane_id) {
                        return open.request_id;
                    }

                    return error.UnexpectedPaneTarget;
                },
                .pane_resize, .pane_input, .frame_ack => {},
                else => return error.UnexpectedClientMessage,
            }
        }
    }

    fn discoverAndRequestAttachment(harness: *TestHarness, pane_id: schema.PaneId, buffer: []u8) !schema.RequestId {
        const snapshot = try schema.encodeTabSnapshot(buffer, .{
            .request_id = @enumFromInt(3),
            .location = bootstrap_location,
            .panes = &.{
                .{ .pane_id = bootstrap_pane, .lifecycle = .running },
                .{ .pane_id = pane_id, .lifecycle = .running },
            },
        });
        _ = try server_messages.handleServerMessage(harness.client, try schema.decodeServer(snapshot));
        try harness.settle();

        return harness.nextAttachmentRequest(pane_id, buffer);
    }

    const bootstrap_location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const bootstrap_pane: schema.PaneId = @enumFromInt(10);

    /// Answers the initial open request through the real entrypoint, leaving
    /// the client with one attached pane and its two snapshot requests (ids
    /// 2 and 3) delivered to the peer.
    fn bootstrap(harness: *TestHarness) !void {
        try harness.client.requests.add(initial_request_id, .{ .initial_open = .{} });
        var payload: [128]u8 = undefined;
        const opened = try schema.encodePaneOpened(&payload, .{
            .request_id = initial_request_id,
            .pane_id = bootstrap_pane,
            .location = bootstrap_location,
            .created = true,
        });
        try std.testing.expectEqual(
            @as(?u8, null),
            try server_messages.handleServerMessage(harness.client, try schema.decodeServer(opened)),
        );
        try harness.settle();
        var buffer: [256]u8 = undefined;
        const first = try harness.nextClientMessage(&buffer);
        try std.testing.expect(first == .request_workspace_snapshot);
        const second = try harness.nextClientMessage(&buffer);
        try std.testing.expect(second == .request_tab_snapshot);
        try harness.client.observeModel();
        try harness.settleModelPresentation();
    }

    fn addTab(harness: *TestHarness, tab_id: schema.TabId, pane_id: schema.PaneId) !schema.TabLocation {
        const location: schema.TabLocation = .{
            .workspace = bootstrap_location.workspace,
            .tab_id = tab_id,
        };

        _ = try harness.client.model.workspace.addCreated(.{
            .location = location,
            .position = @intCast(harness.client.model.workspace.count),
            .label = "second",
            .root_pane_id = pane_id,
        }, .{ .cols = 80, .rows = 24 });

        return location;
    }

    fn addInactiveTab(harness: *TestHarness, tab_id: schema.TabId, pane_id: schema.PaneId) !schema.TabLocation {
        const location = try harness.addTab(tab_id, pane_id);
        const tab = harness.client.model.workspace.find(tab_id).?;
        workspace_capability.tabs.Model.detachAll(tab);
        try harness.client.graphics_store.setPaneVisible(pane_id, false);
        try std.testing.expect(harness.client.model.workspace.select(bootstrap_location.tab_id));

        return location;
    }

    fn allowTabSelection(harness: *TestHarness) !void {
        const continuation = harness.client.requests.take(@enumFromInt(3)) orelse
            return error.MissingBootstrapTabSnapshot;
        try std.testing.expect(continuation == .tab_snapshot);
    }
};

test "host input arriving while no tab exists is dropped, not a crash" {
    // The workspace-handoff window: `tabs.deinit()` has run and the new
    // pane has not been confirmed. A keystroke here used to null-unwrap.
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    var chunk: InputChunk = .{};
    chunk.bytes[0] = 'x';
    chunk.len = 1;
    try std.testing.expect(!try harness.client.handleHostInput(chunk));
    try std.testing.expectEqual(@as(usize, 0), harness.client.outbox.len);
}

test "bootstrap answers the initial open with both snapshot requests" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();

    try std.testing.expectEqual(@as(usize, 1), harness.client.model.workspace.count);
    const pane = harness.client.model.workspace.findPane(TestHarness.bootstrap_pane).?;
    try std.testing.expect(pane.attached);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, harness.client.reported_focus);
    try std.testing.expectEqual(@as(u64, 1), harness.client.model.version().workspace);
    try std.testing.expectEqual(@as(u64, 1), harness.client.model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), harness.client.model.version().active_tab);
    try std.testing.expectEqual(@as(u64, 1), harness.client.model.version().panes);
    try std.testing.expectEqualDeep(
        harness.client.model.version(),
        harness.client.presenter.presented_model_version,
    );
}

test "new tab inherits cwd from the focused runtime pane" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    harness.client.options.arguments = &.{"/bin/sh"};

    var handler: InputHandler = .{ .client = harness.client };
    _ = try handler.applyNativeAction(.new_tab);
    try harness.settle();

    var buffer: [512]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .create_tab);
    const created = message.create_tab;
    try std.testing.expectEqual(TestHarness.bootstrap_pane, created.launch.cwd_source.?);
}

test "new pane inherits cwd from the focused runtime pane" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    harness.client.options.arguments = &.{"/bin/sh"};

    var handler: InputHandler = .{ .client = harness.client };
    _ = try handler.applyNativeAction(.{ .split_pane = .horizontal });
    try harness.settle();

    var buffer: [512]u8 = undefined;
    try std.testing.expect((try harness.nextClientMessage(&buffer)) == .pane_resize);
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .create_pane);
    const created = message.create_pane;
    try std.testing.expectEqual(TestHarness.bootstrap_pane, created.launch.cwd_source.?);
}

test "new workspace inherits cwd from the focused runtime pane" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    harness.client.options.arguments = &.{"/bin/sh"};
    harness.client.requests = .{};

    var handler: InputHandler = .{ .client = harness.client };
    _ = try handler.applyNativeAction(.new_workspace);
    try handler.forward("agents\r");
    try harness.settle();

    var buffer: [512]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .create_workspace);
    const created = message.create_workspace;
    try std.testing.expectEqual(TestHarness.bootstrap_pane, created.launch.cwd_source.?);
}

test "workspace handoff opens the pane remembered for that workspace" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.requests = .{};

    const destination: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(2) };
    const restored_pane: schema.PaneId = @enumFromInt(77);
    client.navigation_history.remember(.{
        .location = .{ .workspace = destination, .tab_id = @enumFromInt(8) },
        .pane_id = restored_pane,
    });
    const version_before_departure = client.model.version();
    const pending_updates_before_departure = client.presenter.pending_updates;
    var handler: InputHandler = .{ .client = client };
    try handler.switchWorkspaceResolved(@enumFromInt(2));

    try std.testing.expect(client.model.workspaceLocation() == null);
    try std.testing.expectEqual(@as(usize, 0), client.model.workspace.count);
    try std.testing.expectEqual(version_before_departure.workspace + 1, client.model.version().workspace);
    try std.testing.expectEqual(version_before_departure.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_departure.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(version_before_departure.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_departure, client.presenter.pending_updates);
    try std.testing.expect(client.reported_focus == null);

    try client.observeModel();

    try std.testing.expectEqual(pending_updates_before_departure + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try harness.settle();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
    try std.testing.expectEqual(@as(usize, 0), client.presenter.pending_updates);
    for (client.presenter.screen.front.cells) |cell| {
        try std.testing.expectEqualStrings(" ", cell.text());
        try std.testing.expectEqual(@as(u8, 1), cell.width);
    }
    try client.observeModel();
    try std.testing.expectEqual(@as(usize, 0), client.presenter.pending_updates);

    var buffer: [256]u8 = undefined;
    var target: ?schema.PaneTarget = null;
    var request_id: schema.RequestId = .none;
    while (target == null) switch (try harness.nextClientMessage(&buffer)) {
        .detach_pane => {},
        .open_pane => |open| {
            request_id = open.request_id;
            target = open.target;
        },
        else => return error.UnexpectedClientMessage,
    };
    try std.testing.expectEqualDeep(schema.PaneTarget{ .pane = restored_pane }, target.?);
    const current = client.navigation_history.find(TestHarness.bootstrap_location.workspace).?;
    try std.testing.expectEqual(TestHarness.bootstrap_pane, current.pane_id);
    try std.testing.expect(current.tab_layout != null);

    var payload: [128]u8 = undefined;
    const failed = try schema.encodeRequestFailed(&payload, .{
        .request_id = request_id,
        .code = .pane_not_found,
        .message = "remembered pane closed",
    });
    const version_before_recovery = client.model.version();
    const pending_updates_before_recovery = client.presenter.pending_updates;
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(failed));

    try std.testing.expectEqualDeep(version_before_recovery, client.model.version());
    try std.testing.expectEqual(pending_updates_before_recovery, client.presenter.pending_updates);
    try harness.settle();
    const fallback = (try harness.nextClientMessage(&buffer)).open_pane;
    try std.testing.expectEqualDeep(
        schema.PaneTarget{ .workspace = @enumFromInt(2) },
        fallback.target,
    );
    const retry = client.requests.take(fallback.request_id).?;
    try std.testing.expect(retry == .initial_open);
    try std.testing.expect(retry.initial_open.fallback_workspace == null);
    try std.testing.expect(client.navigation_history.find(destination) == null);
}

test "workspace handoff capacity failure preserves the source model" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.requests = .{};
    while (client.outbox.len < client_outbox.capacity - 1) {
        try client.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const version_before = client.model.version();
    const focus_before = client.reported_focus;
    var handler: InputHandler = .{ .client = client };

    try std.testing.expectError(error.ClientOutboxFull, handler.switchWorkspaceResolved(@enumFromInt(2)));

    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqual(focus_before, client.reported_focus);
    try std.testing.expect(client.navigation_history.find(TestHarness.bootstrap_location.workspace) == null);
    try std.testing.expect(client.requests.has(.tab_snapshot));
}

test "clicking a sidebar agent hands off directly to its pane" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.requests = .{};

    const agent_pane: schema.PaneId = @enumFromInt(91);
    const agent = widgets.sidebar.AgentInput{
        .key = .{ .pane_id = agent_pane, .pane_generation = 2 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(3) },
            .tab_id = @enumFromInt(6),
        },
        .pane_index = 2,
        .provider = .claude,
        .status = .working,
    };
    const left_pane: schema.PaneId = @enumFromInt(90);
    const bottom_right_pane: schema.PaneId = @enumFromInt(92);
    var saved_layout: workspace_capability.layout.Layout = .{};
    try saved_layout.addRoot(left_pane);
    try saved_layout.split(left_pane, agent_pane, .horizontal);
    try saved_layout.split(agent_pane, bottom_right_pane, .vertical);
    client.navigation_history.remember(.{
        .location = agent.location,
        .pane_id = agent_pane,
        .tab_layout = saved_layout,
    });
    _ = try client.view.replaceSidebarSnapshot(.{
        .revision = 1,
        .agents = &.{agent},
    });
    const model = &client.model.workspace.active().?.model;
    _ = try client.view.render(
        &client.presenter.screen,
        &client.model.workspace,
        model,
        true,
        null,
    );
    var handler: InputHandler = .{ .client = client };
    try handler.mouse(.{ .x = 4, .y = 4, .kind = .press });
    try harness.settle();

    var buffer: [256]u8 = undefined;
    var target: ?schema.PaneTarget = null;
    var request_id: schema.RequestId = .none;
    while (target == null) switch (try harness.nextClientMessage(&buffer)) {
        .detach_pane => {},
        .open_pane => |open| {
            request_id = open.request_id;
            target = open.target;
        },
        else => return error.UnexpectedClientMessage,
    };
    try std.testing.expectEqualDeep(schema.PaneTarget{ .pane = agent_pane }, target.?);

    var payload: [128]u8 = undefined;
    const opened = try schema.encodePaneOpened(&payload, .{
        .request_id = request_id,
        .pane_id = agent_pane,
        .location = agent.location,
        .created = false,
    });
    const version_before_arrival = client.model.version();
    const pending_updates_before_arrival = client.presenter.pending_updates;
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(opened));

    try std.testing.expectEqual(version_before_arrival.workspace + 1, client.model.version().workspace);
    try std.testing.expectEqual(version_before_arrival.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_arrival.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(version_before_arrival.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_arrival, client.presenter.pending_updates);

    try client.observeModel();

    try std.testing.expectEqual(pending_updates_before_arrival + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try harness.settle();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
    try std.testing.expectEqualDeep(
        @as(?schema.WorkspaceLocation, agent.location.workspace),
        client.model.workspace.workspace,
    );
    try std.testing.expectEqual(agent.location.tab_id, client.model.workspace.activeConst().?.location.tab_id);
    try std.testing.expectEqual(agent_pane, client.model.workspace.activeConst().?.model.layout.focused().?);

    var tab_snapshot_request: schema.RequestId = .none;
    while (tab_snapshot_request == .none) switch (try harness.nextClientMessage(&buffer)) {
        .request_workspace_snapshot => {},
        .request_tab_snapshot => |request| {
            try std.testing.expectEqualDeep(agent.location, request.location);
            tab_snapshot_request = request.request_id;
        },
        else => return error.UnexpectedClientMessage,
    };
    var snapshot_payload: [256]u8 = undefined;
    const snapshot = try schema.encodeTabSnapshot(&snapshot_payload, .{
        .request_id = tab_snapshot_request,
        .location = agent.location,
        .panes = &.{
            .{ .pane_id = left_pane, .lifecycle = .running },
            .{ .pane_id = agent_pane, .lifecycle = .running },
            .{ .pane_id = bottom_right_pane, .lifecycle = .running },
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(snapshot));

    const restored = &client.model.workspace.activeConst().?.model;
    try std.testing.expectEqual(agent_pane, restored.layout.focused().?);
    try std.testing.expectEqual(@as(u16, 2), restored.displayIndex(agent_pane).?);
    var expected_geometry: workspace_capability.layout.Snapshot = .{};
    var actual_geometry: workspace_capability.layout.Snapshot = .{};
    saved_layout.snapshot(client.view.workbench(), &expected_geometry);
    restored.layout.snapshot(client.view.workbench(), &actual_geometry);
    for ([_]schema.PaneId{ left_pane, agent_pane, bottom_right_pane }) |pane_id|
        try std.testing.expectEqual(
            expected_geometry.find(pane_id).?.outer,
            actual_geometry.find(pane_id).?.outer,
        );
}

test "tab snapshots commit pane revisions before attaching and presenting" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;

    const discovered: schema.PaneId = @enumFromInt(11);
    var payload: [256]u8 = undefined;
    const snapshot = try schema.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(3),
        .location = TestHarness.bootstrap_location,
        .panes = &.{
            .{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running },
            .{ .pane_id = discovered, .lifecycle = .running },
        },
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try server_messages.handleServerMessage(client, try schema.decodeServer(snapshot)),
    );

    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(version_before.workspace, client.model.version().workspace);
    try std.testing.expectEqual(version_before.tabs, client.model.version().tabs);
    try std.testing.expectEqual(version_before.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    const committed_version = client.model.version();
    try client.requests.add(@enumFromInt(90), .{ .tab_snapshot = TestHarness.bootstrap_location });
    const repeated = try schema.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(90),
        .location = TestHarness.bootstrap_location,
        .panes = &.{
            .{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running },
            .{ .pane_id = discovered, .lifecycle = .running },
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(repeated));

    try std.testing.expectEqualDeep(committed_version, client.model.version());
    try std.testing.expect(client.requests.hasPane(.attachment, discovered));
    try std.testing.expectEqual(@as(usize, 2), client.requests.count);

    try client.observeModel();

    try std.testing.expectEqual(pending_updates_before + 1, client.presenter.pending_updates);
    try harness.settle();

    const pane = client.model.workspace.findPane(discovered).?;
    try std.testing.expect(!pane.attached);
    var buffer: [256]u8 = undefined;
    var attach_requested = false;
    while (!attach_requested) {
        switch (try harness.nextClientMessage(&buffer)) {
            .open_pane => |open| {
                try std.testing.expectEqualDeep(
                    schema.PaneTarget{ .pane = discovered },
                    open.target,
                );
                attach_requested = true;
            },
            .pane_resize => {},
            else => return error.UnexpectedClientMessage,
        }
    }

    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
}

test "an identical tab snapshot repairs resources without scheduling a frame" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    var payload: [256]u8 = undefined;
    const initial = try schema.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(3),
        .location = TestHarness.bootstrap_location,
        .panes = &.{.{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running }},
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(initial));
    try client.observeModel();
    try harness.settle();
    try harness.settleModelPresentation();
    const committed_version = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    try client.requests.add(@enumFromInt(90), .{ .tab_snapshot = TestHarness.bootstrap_location });
    const unchanged = try schema.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(90),
        .location = TestHarness.bootstrap_location,
        .panes = &.{.{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running }},
    });

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(unchanged));
    try client.observeModel();

    try std.testing.expectEqualDeep(committed_version, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
}

test "tab reconciliation retires removed pane resources and continuations" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    var payload: [256]u8 = undefined;
    const initial = try schema.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(3),
        .location = TestHarness.bootstrap_location,
        .panes = &.{.{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running }},
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(initial));
    try harness.settle();

    const retired: schema.PaneId = @enumFromInt(11);
    const model = &client.model.workspace.active().?.model;
    try model.split(
        TestHarness.bootstrap_pane,
        retired,
        TestHarness.bootstrap_location,
        .horizontal,
        client.view.workbench(),
    );
    try client.syncPaneFocus(model);
    client.mode = .{ .copy = .init(retired, .{ .x = 0, .y = 0 }, 0) };
    client.paste_pane = retired;
    try client.graphics_store.applyImage(.{
        .pane_id = retired,
        .revision = 1,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        },
    });
    try client.requests.add(@enumFromInt(91), .{ .close_pane = .{
        .pane_id = retired,
        .location = TestHarness.bootstrap_location,
    } });
    try client.requests.add(@enumFromInt(90), .{ .tab_snapshot = TestHarness.bootstrap_location });
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    const reconciled = try schema.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(90),
        .location = TestHarness.bootstrap_location,
        .panes = &.{.{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running }},
    });

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(reconciled));

    try std.testing.expect(client.model.workspace.findPane(retired) == null);
    try std.testing.expect(!client.graphics_store.hasPaneGraphics(retired));
    try std.testing.expect(client.mode == .normal);
    try std.testing.expect(client.paste_pane == null);
    try std.testing.expectEqual(@as(?schema.PaneId, TestHarness.bootstrap_pane), client.reported_focus);
    try std.testing.expect(client.requests.take(@enumFromInt(91)).? == .ignored);
    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);

    try client.observeModel();

    try std.testing.expectEqual(pending_updates_before + 1, client.presenter.pending_updates);
}

test "an unexpected tab snapshot is rejected instead of adopted" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();

    var payload: [256]u8 = undefined;
    const snapshot = try schema.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(99),
        .location = TestHarness.bootstrap_location,
        .panes = &.{},
    });
    try std.testing.expectError(
        error.UnexpectedTabSnapshot,
        server_messages.handleServerMessage(harness.client, try schema.decodeServer(snapshot)),
    );
}

test "workspace snapshots commit semantic revisions before presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;

    var payload: [512]u8 = undefined;
    const snapshot = try schema.encodeWorkspaceSnapshot(&payload, .{
        .request_id = @enumFromInt(2),
        .workspace = TestHarness.bootstrap_location.workspace,
        .name = "main",
        .tabs = &.{
            .{ .tab_id = @enumFromInt(1), .position = 0, .pane_count = 1, .label = "main" },
            .{ .tab_id = @enumFromInt(2), .position = 1, .pane_count = 1, .label = "second" },
        },
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try server_messages.handleServerMessage(client, try schema.decodeServer(snapshot)),
    );

    try std.testing.expectEqual(@as(usize, 2), client.model.workspace.count);
    try std.testing.expect(client.model.workspace.find(@enumFromInt(2)) != null);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqual(version_before.workspace + 1, client.model.version().workspace);
    try std.testing.expectEqual(version_before.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);

    try client.observeModel();

    try std.testing.expectEqual(pending_updates_before + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    const version_before_noop = client.model.version();
    const pending_updates_before_noop = client.presenter.pending_updates;
    try client.requests.add(@enumFromInt(4), .{
        .workspace_snapshot = TestHarness.bootstrap_location.workspace,
    });
    const unchanged = try schema.encodeWorkspaceSnapshot(&payload, .{
        .request_id = @enumFromInt(4),
        .workspace = TestHarness.bootstrap_location.workspace,
        .name = "main",
        .tabs = &.{
            .{ .tab_id = @enumFromInt(1), .position = 0, .pane_count = 1, .label = "main" },
            .{ .tab_id = @enumFromInt(2), .position = 1, .pane_count = 1, .label = "second" },
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(unchanged));
    try client.observeModel();

    try std.testing.expectEqualDeep(version_before_noop, client.model.version());
    try std.testing.expectEqual(pending_updates_before_noop, client.presenter.pending_updates);
}

test "workspace reconciliation retires removed state and restores the new active tab" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second = try harness.addInactiveTab(@enumFromInt(2), @enumFromInt(20));
    try client.requests.add(@enumFromInt(90), .{ .rename_tab = TestHarness.bootstrap_location });
    try client.graphics_store.applyImage(.{
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
    try std.testing.expect(client.graphics_store.hasPaneGraphics(TestHarness.bootstrap_pane));
    const pending_updates_before = client.presenter.pending_updates;

    var payload: [512]u8 = undefined;
    const snapshot = try schema.encodeWorkspaceSnapshot(&payload, .{
        .request_id = @enumFromInt(2),
        .workspace = TestHarness.bootstrap_location.workspace,
        .name = "main",
        .tabs = &.{
            .{ .tab_id = second.tab_id, .position = 0, .pane_count = 1, .label = "second" },
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(snapshot));

    try std.testing.expectEqualDeep(second, client.model.activeTabLocation().?);
    try std.testing.expect(!client.graphics_store.hasPaneGraphics(TestHarness.bootstrap_pane));
    try std.testing.expect(client.graphics_store.paneVisible(@enumFromInt(20)));
    try std.testing.expectEqual(@as(?schema.PaneId, @enumFromInt(20)), client.reported_focus);
    try std.testing.expect(client.requests.take(@enumFromInt(3)).? == .ignored);
    try std.testing.expect(client.requests.take(@enumFromInt(90)).? == .ignored);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const requested = try harness.nextClientMessage(&buffer);
    try std.testing.expect(requested == .request_tab_snapshot);
    try std.testing.expectEqualDeep(second, requested.request_tab_snapshot.location);
}

test "resync required requests one workspace snapshot and coalesces repeats" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.model.workspace.workspace = TestHarness.bootstrap_location.workspace;

    try server_messages.handleResyncRequired(client, .{
        .workspace = TestHarness.bootstrap_location.workspace,
        .workspace_closed = false,
    });
    try server_messages.handleResyncRequired(client, .{
        .workspace = TestHarness.bootstrap_location.workspace,
        .workspace_closed = false,
    });
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const first = try harness.nextClientMessage(&buffer);
    try std.testing.expect(first == .request_workspace_snapshot);
    try std.testing.expect(client.requests.has(.workspace_snapshot));
    try std.testing.expectEqual(@as(usize, 0), client.outbox.len);
}

test "host Enter variants use the keyboard modes received in a pane frame" {
    const cases = [_]struct { modes: schema.frame.InputModes, expected: []const u8 }{
        .{
            .modes = .{ .kitty_keyboard_flags = 5 },
            .expected = "\x1b[13;2u\x1b[13;2u\r\n",
        },
        .{
            .modes = .{ .modify_other_keys_2 = true },
            .expected = "\x1b[27;2;13~\x1b[27;2;13~\r\n",
        },
        .{ .modes = .{}, .expected = "\r\r\r\n" },
    };
    for (cases) |case| {
        var harness: TestHarness = undefined;
        try harness.init();
        defer harness.deinit();
        try harness.bootstrap();

        var payload: [128]u8 = undefined;
        const cells = [_]core.ui.Cell{.{}};
        const snapshot = try schema.encodePaneFrame(&payload, .{
            .pane_id = TestHarness.bootstrap_pane,
            .frame_id = 1,
            .base_frame_id = 0,
            .cols = 1,
            .rows = 1,
            .input_modes = case.modes,
            .scroll = .{ .total_rows = 1, .offset = 0 },
            .spans = &.{.{ .start = 0, .cells = &cells }},
        });
        _ = try server_messages.handleServerMessage(harness.client, try schema.decodeServer(snapshot));
        const host_bytes = "\x1b[13;2u\x1b[27;2;13~\r\n";
        var chunk: InputChunk = .{};
        @memcpy(chunk.bytes[0..host_bytes.len], host_bytes);
        chunk.len = host_bytes.len;
        try std.testing.expect(!try harness.client.handleHostInput(chunk));
        try harness.settle();

        var received: [32]u8 = undefined;
        var received_len: usize = 0;
        var buffer: [256]u8 = undefined;
        while (received_len < case.expected.len) {
            switch (try harness.nextClientMessage(&buffer)) {
                .pane_input => |input| {
                    try std.testing.expectEqual(TestHarness.bootstrap_pane, input.pane_id);
                    try std.testing.expect(input.bytes.len <= received.len - received_len);
                    @memcpy(received[received_len..][0..input.bytes.len], input.bytes);
                    received_len += input.bytes.len;
                },
                .frame_ack => {},
                else => return error.UnexpectedClientMessage,
            }
        }
        try std.testing.expectEqualStrings(case.expected, received[0..received_len]);
    }
}

test "focus reporting emits focus-in only after the pane opts in" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    // Bootstrap synced focus while the pane had focus events off: the focus
    // is remembered, no byte was sent.
    try std.testing.expectEqual(TestHarness.bootstrap_pane, client.reported_focus);
    try std.testing.expect(!client.reported_focus_events);

    const model = &client.model.workspace.active().?.model;
    model.find(TestHarness.bootstrap_pane).?.input_modes.focus_events = true;
    try client.syncPaneFocus(model);
    try harness.settle();

    try std.testing.expect(client.reported_focus_events);
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .pane_input);
    try std.testing.expectEqualStrings("\x1b[I", message.pane_input.bytes);
}

test "an active split commits once and presentation observes the model" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    const split_pane: schema.PaneId = @enumFromInt(21);
    try client.requests.add(@enumFromInt(4), .{ .split = .{
        .target_pane = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .axis = .horizontal,
        .area = client.view.workbench(),
    } });
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    var payload: [128]u8 = undefined;
    const opened = try schema.encodePaneOpened(&payload, .{
        .request_id = @enumFromInt(4),
        .pane_id = split_pane,
        .location = TestHarness.bootstrap_location,
        .created = true,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(opened));

    const pane = client.model.workspace.findPane(split_pane).?;
    try std.testing.expect(pane.attached);
    try std.testing.expectEqual(split_pane, client.model.workspace.active().?.model.layout.focused().?);
    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);

    try client.observeModel();

    try std.testing.expectEqual(pending_updates_before + 1, client.presenter.pending_updates);
}

test "an inactive split is retained detached without a visible revision" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const first = client.model.workspace.active().?;
    const second_location = try harness.addTab(@enumFromInt(2), @enumFromInt(20));
    workspace_capability.tabs.Model.detachAll(first);
    try std.testing.expectEqualDeep(second_location, client.model.activeTabLocation().?);

    const split_pane: schema.PaneId = @enumFromInt(21);
    try client.requests.add(@enumFromInt(4), .{ .split = .{
        .target_pane = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .axis = .horizontal,
        .area = client.view.workbench(),
    } });
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    var payload: [128]u8 = undefined;
    const opened = try schema.encodePaneOpened(&payload, .{
        .request_id = @enumFromInt(4),
        .pane_id = split_pane,
        .location = TestHarness.bootstrap_location,
        .created = true,
    });

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(opened));

    try std.testing.expect(!client.model.workspace.findPane(split_pane).?.attached);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expect(!client.graphics_store.paneVisible(split_pane));
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
    _ = client.requests.take(@enumFromInt(2)) orelse return error.MissingWorkspaceSnapshot;
    _ = try harness.addTab(@enumFromInt(2), @enumFromInt(20));

    const split_pane: schema.PaneId = @enumFromInt(21);
    try client.requests.add(@enumFromInt(4), .{ .split = .{
        .target_pane = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .axis = .horizontal,
        .area = client.view.workbench(),
    } });
    client.requests.ignoreTab(TestHarness.bootstrap_location.tab_id);
    try std.testing.expect(client.model.workspace.remove(TestHarness.bootstrap_location.tab_id));
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    var payload: [128]u8 = undefined;
    const opened = try schema.encodePaneOpened(&payload, .{
        .request_id = @enumFromInt(4),
        .pane_id = split_pane,
        .location = TestHarness.bootstrap_location,
        .created = true,
    });

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(opened));

    try std.testing.expect(client.model.workspace.findPane(split_pane) == null);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
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

    const split_pane: schema.PaneId = @enumFromInt(21);
    try client.requests.add(@enumFromInt(4), .{ .split = .{
        .target_pane = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .axis = .horizontal,
        .area = client.view.workbench(),
    } });
    try std.testing.expect(client.model.workspace.active().?.model.removePane(TestHarness.bootstrap_pane));
    client.requests.ignorePane(TestHarness.bootstrap_pane);
    const version_before = client.model.version();
    var payload: [128]u8 = undefined;
    const opened = try schema.encodePaneOpened(&payload, .{
        .request_id = @enumFromInt(4),
        .pane_id = split_pane,
        .location = TestHarness.bootstrap_location,
        .created = true,
    });

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(opened));

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
    workspace_capability.tabs.Model.detachAll(first);

    try client.requests.add(@enumFromInt(4), .{ .split = .{
        .target_pane = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .axis = .horizontal,
        .area = client.view.workbench(),
    } });
    const version_before = client.model.version();
    var payload: [128]u8 = undefined;
    const failed = try schema.encodeRequestFailed(&payload, .{
        .request_id = @enumFromInt(4),
        .code = .internal,
        .message = "launch failed",
    });

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(failed));

    try std.testing.expectEqual(@as(u8, 0), client.outbox.len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
}

test "a failed split for a retired target is silent" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    try client.requests.add(@enumFromInt(4), .{ .split = .{
        .target_pane = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .axis = .horizontal,
        .area = client.view.workbench(),
    } });
    try std.testing.expect(client.model.workspace.active().?.model.removePane(TestHarness.bootstrap_pane));
    client.requests.ignorePane(TestHarness.bootstrap_pane);
    const pending_updates_before = client.presenter.pending_updates;
    var payload: [128]u8 = undefined;
    const failed = try schema.encodeRequestFailed(&payload, .{
        .request_id = @enumFromInt(4),
        .code = .pane_not_found,
        .message = "target exited",
    });

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(failed));

    try std.testing.expectEqual(@as(u8, 0), client.outbox.len);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
}

test "an attach reply marks the discovered pane attached" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    const discovered: schema.PaneId = @enumFromInt(11);
    var payload: [256]u8 = undefined;
    const attachment_request = try harness.discoverAndRequestAttachment(discovered, &payload);
    try std.testing.expect(!client.model.workspace.findPane(discovered).?.attached);

    const version_before_confirmation = client.model.version();
    const pending_updates_before_confirmation = client.presenter.pending_updates;

    const opened = try schema.encodePaneOpened(&payload, .{
        .request_id = attachment_request,
        .pane_id = discovered,
        .location = TestHarness.bootstrap_location,
        .created = false,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(opened));

    try std.testing.expect(client.model.workspace.findPane(discovered).?.attached);
    try std.testing.expectEqualDeep(version_before_confirmation, client.model.version());
    try std.testing.expectEqual(pending_updates_before_confirmation, client.presenter.pending_updates);
}

test "tab detachment retires an in-flight pane attachment" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    const discovered: schema.PaneId = @enumFromInt(11);
    var payload: [256]u8 = undefined;
    const attachment_request = try harness.discoverAndRequestAttachment(discovered, &payload);
    try tab_attachments.detach(client, client.model.workspace.active().?);
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
    try std.testing.expect(!client.requests.hasPane(.attachment, discovered));

    const pending_updates_before_confirmation = client.presenter.pending_updates;
    const opened = try schema.encodePaneOpened(&payload, .{
        .request_id = attachment_request,
        .pane_id = discovered,
        .location = TestHarness.bootstrap_location,
        .created = false,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(opened));

    try std.testing.expect(!client.model.workspace.findPane(discovered).?.attached);
    try std.testing.expectEqual(pending_updates_before_confirmation, client.presenter.pending_updates);
}

test "a missing pane attachment keeps local membership until a canonical snapshot" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    const discovered: schema.PaneId = @enumFromInt(11);
    var payload: [256]u8 = undefined;
    const attachment_request = try harness.discoverAndRequestAttachment(discovered, &payload);
    const version_before_failure = client.model.version();

    const failed = try schema.encodeRequestFailed(&payload, .{
        .request_id = attachment_request,
        .code = .pane_not_found,
        .message = "pane disappeared",
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(failed));

    const pane = client.model.workspace.findPane(discovered) orelse return error.PaneRemovedBeforeSnapshot;
    try std.testing.expect(!pane.attached);
    try std.testing.expectEqualDeep(version_before_failure, client.model.version());
    try std.testing.expect(client.requests.has(.tab_snapshot));
    try harness.settle();

    var message_buffer: [256]u8 = undefined;
    const recovery = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(recovery == .request_tab_snapshot);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, recovery.request_tab_snapshot.location);
    try std.testing.expect(client.notification_tick_pending);
}

test "an internal pane attachment failure waits for a later resync" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    const discovered: schema.PaneId = @enumFromInt(11);
    var payload: [256]u8 = undefined;
    const attachment_request = try harness.discoverAndRequestAttachment(discovered, &payload);
    const version_before_failure = client.model.version();

    const failed = try schema.encodeRequestFailed(&payload, .{
        .request_id = attachment_request,
        .code = .internal,
        .message = "resize failed",
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(failed));

    const pane = client.model.workspace.findPane(discovered) orelse return error.PaneRemovedAfterInternalFailure;
    try std.testing.expect(!pane.attached);
    try std.testing.expectEqualDeep(version_before_failure, client.model.version());
    try std.testing.expect(!client.requests.has(.tab_snapshot));
    try std.testing.expectEqual(@as(usize, 0), client.outbox.len);
    try std.testing.expect(client.notification_tick_pending);
}

test "a late pane attachment confirmation retired by a snapshot is ignored" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    const discovered: schema.PaneId = @enumFromInt(11);
    var payload: [256]u8 = undefined;
    const attachment_request = try harness.discoverAndRequestAttachment(discovered, &payload);
    try client.requests.add(@enumFromInt(90), .{ .tab_snapshot = TestHarness.bootstrap_location });

    const reconciled = try schema.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(90),
        .location = TestHarness.bootstrap_location,
        .panes = &.{.{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running }},
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(reconciled));
    try std.testing.expect(client.model.workspace.findPane(discovered) == null);
    const pending_updates_before_confirmation = client.presenter.pending_updates;

    const opened = try schema.encodePaneOpened(&payload, .{
        .request_id = attachment_request,
        .pane_id = discovered,
        .location = TestHarness.bootstrap_location,
        .created = false,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(opened));

    try std.testing.expectEqual(pending_updates_before_confirmation, client.presenter.pending_updates);
}

test "a late failed pane attachment does not notify or draw" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    try client.requests.add(@enumFromInt(4), .{ .attach_pane = .{
        .pane_id = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
    } });
    try std.testing.expect(client.requests.ignoreAttachment(TestHarness.bootstrap_pane));
    const pending_updates_before_failure = client.presenter.pending_updates;
    var payload: [256]u8 = undefined;
    const failed = try schema.encodeRequestFailed(&payload, .{
        .request_id = @enumFromInt(4),
        .code = .pane_not_found,
        .message = "pane disappeared",
    });

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(failed));

    try std.testing.expectEqual(pending_updates_before_failure, client.presenter.pending_updates);
    try std.testing.expect(!client.notification_tick_pending);
    try std.testing.expectEqual(@as(usize, 0), client.outbox.len);
}

test "a created workspace bookmarks and replaces the prior layout" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    const prior_location = TestHarness.bootstrap_location;
    const left = TestHarness.bootstrap_pane;
    const top_right: schema.PaneId = @enumFromInt(11);
    const bottom_right: schema.PaneId = @enumFromInt(12);
    const workbench = client.view.workbench();
    const prior_model = &client.model.workspace.active().?.model;
    try prior_model.split(left, top_right, prior_location, .horizontal, workbench);
    try prior_model.split(top_right, bottom_right, prior_location, .vertical, workbench);
    var expected_geometry: workspace_capability.layout.Snapshot = .{};
    prior_model.layout.snapshot(workbench, &expected_geometry);

    const new_location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(5),
    };
    try client.requests.add(@enumFromInt(4), .create_workspace);
    var payload: [128]u8 = undefined;
    const opened = try schema.encodePaneOpened(&payload, .{
        .request_id = @enumFromInt(4),
        .pane_id = @enumFromInt(30),
        .location = new_location,
        .created = true,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(opened));
    try harness.settle();

    try std.testing.expect(!client.notification_tick_pending);
    try std.testing.expectEqualDeep(
        @as(?schema.WorkspaceLocation, new_location.workspace),
        client.model.workspace.workspace,
    );
    try std.testing.expect(client.model.workspace.findPane(@enumFromInt(30)) != null);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane) == null);

    const bookmark = client.navigation_history.find(prior_location.workspace).?;
    try std.testing.expectEqual(prior_location, bookmark.location);
    try std.testing.expectEqual(bottom_right, bookmark.pane_id);
    const saved_layout = bookmark.tab_layout.?;
    var saved_geometry: workspace_capability.layout.Snapshot = .{};
    saved_layout.snapshot(workbench, &saved_geometry);
    for ([_]schema.PaneId{ left, top_right, bottom_right }) |pane_id|
        try std.testing.expectEqual(
            expected_geometry.find(pane_id).?.outer,
            saved_geometry.find(pane_id).?.outer,
        );

    // Return through the same runtime handoff used by workspace selection.
    // The requests emitted while bootstrapping the created workspace are not
    // relevant to this transition, but their encoded messages still precede
    // the detach and open below.
    client.requests = .{};
    var handler: InputHandler = .{ .client = client };
    try handler.switchWorkspaceResolved(prior_location.workspace.workspace);
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    var open_request: schema.RequestId = .none;
    while (open_request == .none) switch (try harness.nextClientMessage(&message_buffer)) {
        .request_workspace_snapshot, .request_tab_snapshot, .detach_pane => {},
        .open_pane => |open| {
            try std.testing.expectEqualDeep(schema.PaneTarget{ .pane = bottom_right }, open.target);
            open_request = open.request_id;
        },
        else => return error.UnexpectedClientMessage,
    };

    const reopened = try schema.encodePaneOpened(&payload, .{
        .request_id = open_request,
        .pane_id = bottom_right,
        .location = prior_location,
        .created = false,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(reopened));
    try harness.settle();
    var snapshot_request: schema.RequestId = .none;
    while (snapshot_request == .none) switch (try harness.nextClientMessage(&message_buffer)) {
        .request_workspace_snapshot => {},
        .request_tab_snapshot => |request| {
            try std.testing.expectEqual(prior_location, request.location);
            snapshot_request = request.request_id;
        },
        else => return error.UnexpectedClientMessage,
    };
    var snapshot_payload: [256]u8 = undefined;
    const snapshot = try schema.encodeTabSnapshot(&snapshot_payload, .{
        .request_id = snapshot_request,
        .location = prior_location,
        .panes = &.{
            .{ .pane_id = left, .lifecycle = .running },
            .{ .pane_id = top_right, .lifecycle = .running },
            .{ .pane_id = bottom_right, .lifecycle = .running },
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(snapshot));

    var restored_geometry: workspace_capability.layout.Snapshot = .{};
    client.model.workspace.activeConst().?.model.layout.snapshot(workbench, &restored_geometry);
    for ([_]schema.PaneId{ left, top_right, bottom_right }) |pane_id|
        try std.testing.expectEqual(
            expected_geometry.find(pane_id).?.outer,
            restored_geometry.find(pane_id).?.outer,
        );
}

test "tab lifecycle: created, renamed, moved, closed" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    try harness.allowTabSelection();
    const client = harness.client;
    const workspace = TestHarness.bootstrap_location.workspace;
    const second_location: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    var payload: [256]u8 = undefined;

    // Created: the new tab becomes active and the old one detaches.
    const version_before_creation = client.model.version();
    const pending_updates_before_creation = client.presenter.pending_updates;
    try client.requests.add(@enumFromInt(4), .{ .create_tab = workspace });
    const created = try schema.encodeTabCreated(&payload, .{
        .request_id = @enumFromInt(4),
        .location = second_location,
        .position = 1,
        .label = "second",
        .root_pane_id = @enumFromInt(20),
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(created));

    try std.testing.expect(!client.notification_tick_pending);
    try std.testing.expectEqual(@as(usize, 2), client.model.workspace.count);
    try std.testing.expectEqual(second_location.tab_id, client.model.workspace.active().?.location.tab_id);
    try std.testing.expectEqual(version_before_creation.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_creation.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before_creation, client.presenter.pending_updates);
    try std.testing.expect(!client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expect(client.model.workspace.findPane(@enumFromInt(20)).?.attached);

    try client.observeModel();

    try std.testing.expectEqual(pending_updates_before_creation + 1, client.presenter.pending_updates);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const detached = try harness.nextClientMessage(&buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, detached.detach_pane.pane_id);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    // Renamed.
    const version_before_rename = client.model.version();
    const pending_updates_before_rename = client.presenter.pending_updates;
    try client.requests.add(@enumFromInt(5), .{ .rename_tab = second_location });
    const renamed = try schema.encodeTabRenamed(&payload, .{
        .request_id = @enumFromInt(5),
        .location = second_location,
        .label = "renamed",
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(renamed));
    try std.testing.expectEqualStrings(
        "renamed",
        client.model.workspace.find(second_location.tab_id).?.labelSlice(),
    );
    try std.testing.expectEqual(version_before_rename.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_rename.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before_rename, client.presenter.pending_updates);
    try std.testing.expect(!client.notification_tick_pending);

    try client.observeModel();

    try std.testing.expectEqual(pending_updates_before_rename + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    // Moved to the front.
    try client.requests.add(@enumFromInt(6), .{ .move_tab = second_location });
    const moved = try schema.encodeTabMoved(&payload, .{
        .request_id = @enumFromInt(6),
        .location = second_location,
        .position = 0,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(moved));
    try std.testing.expectEqual(@as(?usize, 0), client.model.workspace.indexOf(second_location.tab_id));

    // Requested close of the active tab: the semantic commit precedes
    // cleanup, and the presenter observes it independently.
    try client.graphics_store.applyImage(.{ .pane_id = @enumFromInt(20), .revision = 1, .image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgb,
        .width = 1,
        .height = 1,
        .byte_len = 3,
    } });
    client.mode = .{ .copy = .init(@enumFromInt(20), .{ .x = 0, .y = 0 }, 0) };
    client.paste_pane = @enumFromInt(20);
    try std.testing.expect(client.graphics_store.hasPaneGraphics(@enumFromInt(20)));
    const version_before_close = client.model.version();
    const pending_updates_before_close = client.presenter.pending_updates;
    try client.requests.add(@enumFromInt(7), .{ .close_tab = second_location });
    const closed = try schema.encodeTabClosed(&payload, .{
        .request_id = @enumFromInt(7),
        .location = second_location,
        .workspace_closed = false,
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try server_messages.handleServerMessage(client, try schema.decodeServer(closed)),
    );

    try std.testing.expectEqual(@as(usize, 1), client.model.workspace.count);
    try std.testing.expectEqual(
        TestHarness.bootstrap_location.tab_id,
        client.model.workspace.active().?.location.tab_id,
    );
    try std.testing.expectEqual(version_before_close.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_close.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before_close, client.presenter.pending_updates);
    try std.testing.expect(!client.graphics_store.hasPaneGraphics(@enumFromInt(20)));
    try std.testing.expect(client.mode == .normal);
    try std.testing.expect(client.paste_pane == null);

    try client.observeModel();

    try std.testing.expectEqual(pending_updates_before_close + 1, client.presenter.pending_updates);
    try harness.settle();
    const survivor_snapshot = try harness.nextClientMessage(&buffer);
    try std.testing.expect(survivor_snapshot == .request_tab_snapshot);
    try std.testing.expectEqualDeep(
        TestHarness.bootstrap_location,
        survivor_snapshot.request_tab_snapshot.location,
    );
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    // An unknown close request is rejected.
    const unexpected = try schema.encodeTabClosed(&payload, .{
        .request_id = @enumFromInt(99),
        .location = second_location,
        .workspace_closed = false,
    });
    try std.testing.expectError(
        error.UnexpectedTabClosed,
        server_messages.handleServerMessage(client, try schema.decodeServer(unexpected)),
    );
}

test "rejected tab creation leaves the active tab attached" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before_creation = client.model.version();
    const pending_updates_before_creation = client.presenter.pending_updates;
    try client.requests.add(@enumFromInt(4), .{
        .create_tab = TestHarness.bootstrap_location.workspace,
    });
    var payload: [256]u8 = undefined;
    const duplicate = try schema.encodeTabCreated(&payload, .{
        .request_id = @enumFromInt(4),
        .location = TestHarness.bootstrap_location,
        .position = 1,
        .label = "duplicate",
        .root_pane_id = @enumFromInt(20),
    });

    try std.testing.expectError(
        error.TabAlreadyExists,
        server_messages.handleServerMessage(client, try schema.decodeServer(duplicate)),
    );

    try std.testing.expectEqual(@as(usize, 1), client.model.workspace.count);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqualDeep(version_before_creation, client.model.version());
    try std.testing.expectEqual(pending_updates_before_creation, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 0), client.outbox.len);
}

test "move tab waits for the canonical response and preserves active identity" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second = try harness.addTab(@enumFromInt(2), @enumFromInt(20));
    var handler: InputHandler = .{ .client = client };

    _ = try handler.applyNativeAction(.{ .move_tab = .previous });

    try std.testing.expectEqual(@as(?usize, 1), client.model.workspace.indexOf(second.tab_id));
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(message == .move_tab);
    try std.testing.expectEqualDeep(second, message.move_tab.location);
    try std.testing.expectEqual(schema.TabMoveDirection.previous, message.move_tab.direction);
    try std.testing.expectEqual(@as(?usize, 1), client.model.workspace.indexOf(second.tab_id));

    try std.testing.expect(client.model.workspace.select(TestHarness.bootstrap_location.tab_id));
    const version_before_response = client.model.version();
    const pending_updates_before_response = client.presenter.pending_updates;
    var response_buffer: [256]u8 = undefined;
    const response = try schema.encodeTabMoved(&response_buffer, .{
        .request_id = message.move_tab.request_id,
        .location = second,
        .position = 0,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(response));

    try std.testing.expectEqual(@as(?usize, 0), client.model.workspace.indexOf(second.tab_id));
    try std.testing.expectEqual(TestHarness.bootstrap_location.tab_id, client.model.workspace.activeConst().?.location.tab_id);
    try std.testing.expectEqual(version_before_response.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_response.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before_response, client.presenter.pending_updates);

    try client.observeModel();

    try std.testing.expectEqualDeep(client.model.version(), client.presenter.observed_model_version);
    try std.testing.expectEqual(pending_updates_before_response + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
}

test "pending tab operation suppresses a move request" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second = try harness.addTab(@enumFromInt(2), @enumFromInt(20));
    try client.requests.add(@enumFromInt(90), .{ .rename_tab = second });
    const request_count = client.requests.count;
    const next_request_id = client.next_request_id;
    var handler: InputHandler = .{ .client = client };

    _ = try handler.applyNativeAction(.{ .move_tab = .previous });

    try std.testing.expectEqual(request_count, client.requests.count);
    try std.testing.expectEqual(next_request_id, client.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.outbox.len);
    try std.testing.expectEqual(@as(?usize, 1), client.model.workspace.indexOf(second.tab_id));
}

test "canonical tab move at an edge does not advance or schedule the model" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    var handler: InputHandler = .{ .client = client };

    _ = try handler.applyNativeAction(.{ .move_tab = .previous });
    try harness.settle();

    var message_buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(message == .move_tab);
    const version_before_response = client.model.version();
    const pending_updates_before_response = client.presenter.pending_updates;

    var response_buffer: [256]u8 = undefined;
    const response = try schema.encodeTabMoved(&response_buffer, .{
        .request_id = message.move_tab.request_id,
        .location = message.move_tab.location,
        .position = 0,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(response));
    try client.observeModel();

    try std.testing.expectEqualDeep(version_before_response, client.model.version());
    try std.testing.expectEqual(pending_updates_before_response, client.presenter.pending_updates);
    try std.testing.expect(!client.requests.has(.tab_operation));
}

test "select tab detaches the current tab before requesting the target snapshot" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    try harness.allowTabSelection();
    const client = harness.client;
    const second_pane: schema.PaneId = @enumFromInt(20);
    const second = try harness.addInactiveTab(@enumFromInt(2), second_pane);
    const selected_model = &client.model.workspace.find(second.tab_id).?.model;
    selected_model.composition_invalidated = false;
    const version_before_selection = client.model.version();
    const pending_updates_before_selection = client.presenter.pending_updates;
    var handler: InputHandler = .{ .client = client };

    _ = try handler.applyNativeAction(.{ .select_tab = 1 });

    try std.testing.expectEqual(second, client.model.activeTabLocation().?);
    try std.testing.expectEqual(version_before_selection.tabs, client.model.version().tabs);
    try std.testing.expectEqual(version_before_selection.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before_selection, client.presenter.pending_updates);
    try std.testing.expect(!handler.redraw);
    try std.testing.expect(!selected_model.composition_invalidated);
    try std.testing.expect(!client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expect(!client.model.workspace.findPane(second_pane).?.attached);
    try std.testing.expect(!client.graphics_store.paneVisible(TestHarness.bootstrap_pane));
    try std.testing.expect(client.graphics_store.paneVisible(second_pane));

    try client.observeModel();

    try std.testing.expectEqual(pending_updates_before_selection + 1, client.presenter.pending_updates);
    try harness.settle();

    var message_buffer: [256]u8 = undefined;
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, detached.detach_pane.pane_id);
    const snapshot = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(snapshot == .request_tab_snapshot);
    try std.testing.expectEqualDeep(second, snapshot.request_tab_snapshot.location);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
}

test "pending tab snapshot suppresses tab selection without effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second_pane: schema.PaneId = @enumFromInt(20);
    _ = try harness.addInactiveTab(@enumFromInt(2), second_pane);
    const version_before_selection = client.model.version();
    const next_request_id = client.next_request_id;
    var handler: InputHandler = .{ .client = client };

    _ = try handler.applyNativeAction(.{ .select_tab = 1 });

    try std.testing.expectEqual(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expect(!client.model.workspace.findPane(second_pane).?.attached);
    try std.testing.expectEqualDeep(version_before_selection, client.model.version());
    try std.testing.expectEqual(next_request_id, client.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.outbox.len);
    try std.testing.expect(!handler.redraw);
}

test "close tab request detaches before delivery and rejection requests restoration" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.requests = .{};
    const version_before_request = client.model.version();
    const pending_updates_before_request = client.presenter.pending_updates;
    var handler: InputHandler = .{ .client = client };

    _ = try handler.applyNativeAction(.close_tab);

    try std.testing.expectEqualDeep(version_before_request, client.model.version());
    try std.testing.expectEqual(pending_updates_before_request, client.presenter.pending_updates);
    try std.testing.expect(!handler.redraw);
    try std.testing.expect(!client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);

    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, detached.detach_pane.pane_id);
    const requested = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(requested == .close_tab);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, requested.close_tab.location);

    var failure_buffer: [256]u8 = undefined;
    const failed = try schema.encodeRequestFailed(&failure_buffer, .{
        .request_id = requested.close_tab.request_id,
        .code = .internal,
        .message = "close rejected",
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(failed));
    try harness.settle();

    const recovery = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(recovery == .request_tab_snapshot);
    try std.testing.expectEqualDeep(
        TestHarness.bootstrap_location,
        recovery.request_tab_snapshot.location,
    );
    try std.testing.expect(client.notification_tick_pending);
    try std.testing.expectEqualDeep(version_before_request, client.model.version());
}

test "inactive tab lifecycle closure changes only the tab collection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.requests = .{};
    const second_pane: schema.PaneId = @enumFromInt(20);
    const second = try harness.addInactiveTab(@enumFromInt(2), second_pane);
    try client.graphics_store.applyImage(.{ .pane_id = second_pane, .revision = 1, .image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgb,
        .width = 1,
        .height = 1,
        .byte_len = 3,
    } });
    const version_before_close = client.model.version();
    const pending_updates_before_close = client.presenter.pending_updates;

    var payload: [128]u8 = undefined;
    const closed = try schema.encodeTabClosed(&payload, .{
        .request_id = .none,
        .location = second,
        .workspace_closed = false,
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try server_messages.handleServerMessage(client, try schema.decodeServer(closed)),
    );

    try std.testing.expectEqual(@as(usize, 1), client.model.workspace.count);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqual(version_before_close.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_close.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before_close, client.presenter.pending_updates);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expect(!client.graphics_store.hasPaneGraphics(second_pane));
    try std.testing.expectEqual(@as(usize, 0), client.outbox.len);

    try client.observeModel();

    try std.testing.expectEqual(pending_updates_before_close + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
}

test "invalid last tab closure has no semantic or cleanup effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.requests = .{};
    try client.graphics_store.applyImage(.{ .pane_id = TestHarness.bootstrap_pane, .revision = 1, .image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgb,
        .width = 1,
        .height = 1,
        .byte_len = 3,
    } });
    try client.requests.add(@enumFromInt(4), .{ .close_tab = TestHarness.bootstrap_location });
    try client.requests.add(@enumFromInt(90), .{ .tab_snapshot = TestHarness.bootstrap_location });
    const version_before_close = client.model.version();
    const pending_updates_before_close = client.presenter.pending_updates;

    var payload: [128]u8 = undefined;
    const closed = try schema.encodeTabClosed(&payload, .{
        .request_id = @enumFromInt(4),
        .location = TestHarness.bootstrap_location,
        .workspace_closed = false,
    });
    try std.testing.expectError(
        error.UnexpectedWorkspaceClosure,
        server_messages.handleServerMessage(client, try schema.decodeServer(closed)),
    );

    try std.testing.expectEqual(@as(usize, 1), client.model.workspace.count);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expect(client.graphics_store.hasPaneGraphics(TestHarness.bootstrap_pane));
    try std.testing.expectEqualDeep(version_before_close, client.model.version());
    try std.testing.expectEqual(pending_updates_before_close, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 0), client.outbox.len);
    try std.testing.expect(client.requests.take(@enumFromInt(90)).? == .tab_snapshot);
}

test "closing the last workspace exits the client" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.requests = .{};
    try client.graphics_store.applyImage(.{ .pane_id = TestHarness.bootstrap_pane, .revision = 1, .image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgb,
        .width = 1,
        .height = 1,
        .byte_len = 3,
    } });
    const version_before_close = client.model.version();

    var payload: [128]u8 = undefined;
    const closed = try schema.encodeTabClosed(&payload, .{
        .request_id = .none,
        .location = TestHarness.bootstrap_location,
        .workspace_closed = true,
    });
    try std.testing.expectEqual(
        @as(?u8, 0),
        try server_messages.handleServerMessage(client, try schema.decodeServer(closed)),
    );
    try std.testing.expectEqual(@as(usize, 0), client.model.workspace.count);
    try std.testing.expect(client.model.activeTabLocation() == null);
    try std.testing.expectEqual(version_before_close.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_close.active_tab + 1, client.model.version().active_tab);
    try std.testing.expect(!client.graphics_store.hasPaneGraphics(TestHarness.bootstrap_pane));
    try std.testing.expectEqual(@as(?schema.PaneId, null), client.reported_focus);
}

test "a closed workspace with a survivor starts a handoff to it" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    var payload: [128]u8 = undefined;
    const resync = try schema.encodeResyncRequired(&payload, .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .workspace_closed = true,
        .previous_workspace = @enumFromInt(2),
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try server_messages.handleServerMessage(harness.client, try schema.decodeServer(resync)),
    );
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .open_pane);
    try std.testing.expectEqualDeep(
        schema.PaneTarget{ .workspace = @enumFromInt(2) },
        message.open_pane.target,
    );
}

test "a patch against an unknown base requests a fresh snapshot" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    var payload: [512]u8 = undefined;
    const patch = try schema.encodePaneFrame(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .frame_id = 5,
        .base_frame_id = 4,
        .cols = 40,
        .rows = 10,
        .scroll = .{ .total_rows = 10, .offset = 0 },
        .spans = &.{},
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(patch));
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .request_snapshot);
    try std.testing.expectEqual(@as(u64, 0), message.request_snapshot.known_frame_id);

    // A full snapshot applies and is acknowledged on the next present. A
    // snapshot must carry exactly one span covering the whole grid.
    const blank: core.ui.Cell = .{};
    const cells: [4]core.ui.Cell = @splat(blank);
    const snapshot = try schema.encodePaneFrame(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .frame_id = 5,
        .base_frame_id = 0,
        .cols = 2,
        .rows = 2,
        .scroll = .{ .total_rows = 2, .offset = 0 },
        .spans = &.{.{ .start = 0, .cells = &cells }},
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(snapshot));
    try std.testing.expectEqual(
        @as(u64, 5),
        client.model.workspace.findPane(TestHarness.bootstrap_pane).?.applied_frame_id,
    );
    try harness.settle();
}

test "a pane cwd report lands on the pane" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();

    var payload: [128]u8 = undefined;
    const cwd = try schema.encodePaneCwd(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .cwd = "/work/telar",
    });
    _ = try server_messages.handleServerMessage(harness.client, try schema.decodeServer(cwd));
    try harness.settle();
    try std.testing.expectEqualStrings(
        "/work/telar",
        harness.client.model.workspace.findPane(TestHarness.bootstrap_pane).?.cwdSlice(),
    );
}

test "a foreground report renames the pane" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();

    var payload: [128]u8 = undefined;
    const foreground = try schema.encodePaneForeground(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .name = "Claude Code",
    });
    _ = try server_messages.handleServerMessage(
        harness.client,
        try schema.decodeServer(foreground),
    );
    try harness.settle();
    try std.testing.expectEqualStrings(
        "Claude Code",
        harness.client.model.workspace.findPane(TestHarness.bootstrap_pane).?.foregroundName(),
    );
}

test "close pane request waits for the authoritative exit before committing" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.requests = .{};
    const closing_pane: schema.PaneId = @enumFromInt(11);
    const split = try client.model.commitPaneSplit(.{
        .split = .{
            .target_pane = TestHarness.bootstrap_pane,
            .location = TestHarness.bootstrap_location,
            .axis = .horizontal,
            .area = client.view.workbench(),
        },
        .new_pane = closing_pane,
    });
    try std.testing.expect(split.change == .changed);
    try client.observeModel();
    try harness.settleModelPresentation();
    client.reported_focus = closing_pane;
    client.paste_pane = closing_pane;
    try client.graphics_store.applyImage(.{
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
    const pending_updates_before_request = client.presenter.pending_updates;
    var handler: InputHandler = .{ .client = client };

    _ = try handler.applyNativeAction(.close_pane);

    try std.testing.expect(client.model.workspace.findPane(closing_pane) != null);
    try std.testing.expectEqualDeep(version_before_request, client.model.version());
    try std.testing.expectEqual(pending_updates_before_request, client.presenter.pending_updates);
    try std.testing.expect(!handler.redraw);
    try std.testing.expectEqual(@as(usize, 1), client.requests.count);

    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const requested = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(requested == .close_pane);
    try std.testing.expectEqual(closing_pane, requested.close_pane.pane_id);
    try std.testing.expect(requested.close_pane.request_id != .none);
    client.mode = .{ .copy = .init(closing_pane, .{ .x = 0, .y = 0 }, 0) };

    var payload: [128]u8 = undefined;
    const exited = try schema.encodePaneExited(&payload, .{
        .pane_id = closing_pane,
        .kind = .exited,
        .value = 0,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(exited));

    try std.testing.expect(client.model.workspace.findPane(closing_pane) == null);
    try std.testing.expectEqual(version_before_request.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_request, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 0), client.requests.count);
    try std.testing.expect(client.mode == .normal);
    try std.testing.expect(client.paste_pane == null);
    try std.testing.expectEqual(@as(?schema.PaneId, TestHarness.bootstrap_pane), client.reported_focus);
    try std.testing.expect(!client.graphics_store.hasPaneGraphics(closing_pane));
    try std.testing.expect(!client.notification_tick_pending);

    try client.observeModel();

    try std.testing.expectEqual(pending_updates_before_request + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
    const committed_version = client.model.version();
    const pending_updates_after_commit = client.presenter.pending_updates;

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(exited));
    try client.observeModel();

    try std.testing.expectEqualDeep(committed_version, client.model.version());
    try std.testing.expectEqual(pending_updates_after_commit, client.presenter.pending_updates);
}

test "an unrequested pane exit removes the pane silently" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.mode = .{ .copy = .init(TestHarness.bootstrap_pane, .{ .x = 0, .y = 0 }, 0) };
    client.paste_pane = TestHarness.bootstrap_pane;
    try client.graphics_store.applyImage(.{
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
    const pending_updates_before_exit = client.presenter.pending_updates;

    var payload: [128]u8 = undefined;
    const exited = try schema.encodePaneExited(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .kind = .exited,
        .value = 0,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(exited));
    try harness.settle();

    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane) == null);
    try std.testing.expectEqual(version_before_exit.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_exit, client.presenter.pending_updates);
    try std.testing.expect(client.mode == .normal);
    try std.testing.expect(client.paste_pane == null);
    try std.testing.expectEqual(@as(?schema.PaneId, null), client.reported_focus);
    try std.testing.expect(!client.graphics_store.hasPaneGraphics(TestHarness.bootstrap_pane));
    try std.testing.expect(!client.notification_tick_pending);

    try client.observeModel();

    try std.testing.expectEqual(pending_updates_before_exit + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
}

test "an inactive pane exit retires only inactive state" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.requests = .{};
    const inactive_pane: schema.PaneId = @enumFromInt(20);
    const inactive = try harness.addInactiveTab(@enumFromInt(2), inactive_pane);
    client.paste_pane = inactive_pane;
    try client.graphics_store.applyImage(.{
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
    try client.requests.add(@enumFromInt(4), .{ .close_pane = .{
        .pane_id = inactive_pane,
        .location = inactive,
    } });
    try client.requests.add(@enumFromInt(5), .{ .attach_pane = .{
        .pane_id = inactive_pane,
        .location = inactive,
    } });
    const version_before_exit = client.model.version();
    const pending_updates_before_exit = client.presenter.pending_updates;

    var payload: [128]u8 = undefined;
    const exited = try schema.encodePaneExited(&payload, .{
        .pane_id = inactive_pane,
        .kind = .signaled,
        .value = 15,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(exited));

    try std.testing.expect(client.model.workspace.findPane(inactive_pane) == null);
    try std.testing.expectEqualDeep(version_before_exit, client.model.version());
    try std.testing.expectEqual(pending_updates_before_exit, client.presenter.pending_updates);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqual(@as(?schema.PaneId, TestHarness.bootstrap_pane), client.reported_focus);
    try std.testing.expect(client.paste_pane == null);
    try std.testing.expect(!client.graphics_store.hasPaneGraphics(inactive_pane));
    try std.testing.expect(client.requests.take(@enumFromInt(4)) == null);
    try std.testing.expect(client.requests.take(@enumFromInt(5)).? == .ignored);
    try std.testing.expectEqual(@as(usize, 0), client.requests.count);
    try std.testing.expectEqual(@as(usize, 0), client.outbox.len);

    try client.observeModel();

    try std.testing.expectEqual(pending_updates_before_exit, client.presenter.pending_updates);
}

test "a failed request surfaces as a notification" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    try client.requests.add(@enumFromInt(4), .{ .close_pane = .{
        .pane_id = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
    } });
    var payload: [256]u8 = undefined;
    const failed = try schema.encodeRequestFailed(&payload, .{
        .request_id = @enumFromInt(4),
        .code = .pane_not_found,
        .message = "no such pane",
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(failed));
    try harness.settle();
    try std.testing.expect(client.notification_tick_pending);

    const unknown = try schema.encodeRequestFailed(&payload, .{
        .request_id = @enumFromInt(99),
        .code = .pane_not_found,
        .message = "no such request",
    });
    try std.testing.expectError(
        error.UnexpectedRequestFailure,
        server_messages.handleServerMessage(client, try schema.decodeServer(unknown)),
    );
}

test "runtime notifications and delivery failures reach the toasts" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;

    var payload: [256]u8 = undefined;
    const notification = try schema.encodeNotification(&payload, .{ .title = "hello" });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(notification));
    try std.testing.expect(client.notification_tick_pending);

    try client.requests.add(@enumFromInt(2), .notification);
    const shown = try schema.encodeNotificationShown(&payload, .{
        .request_id = @enumFromInt(2),
        .delivered_clients = 0,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(shown));

    const unexpected = try schema.encodeNotificationShown(&payload, .{
        .request_id = @enumFromInt(9),
        .delivered_clients = 1,
    });
    try std.testing.expectError(
        error.UnexpectedNotificationReply,
        server_messages.handleServerMessage(client, try schema.decodeServer(unexpected)),
    );
    try harness.settle();
}

test "proxy status flips the interception indicator once" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;

    var payload: [64]u8 = undefined;
    const status = try schema.encodeProxyStatus(&payload, .{ .active = true });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(status));
    try std.testing.expect(client.view.proxy_tls_active);
    try harness.settle();
}

test "system metrics schedule a redraw" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    var payload: [64]u8 = undefined;
    const metrics = try schema.encodeSystemMetrics(&payload, .{
        .revision = 1,
        .cpu_percent = 50,
        .memory_used_decigib = 10,
        .has_battery = false,
        .battery_percent = 0,
    });
    _ = try server_messages.handleServerMessage(harness.client, try schema.decodeServer(metrics));
    try std.testing.expect(harness.client.presenter.draw_pending);
    try harness.settle();
}

test "the workspace list replica follows the runtime revision" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    var payload: [512]u8 = undefined;
    const list = try schema.encodeWorkspaceList(&payload, .{
        .revision = 1,
        .entries = &.{
            .{ .workspace = @enumFromInt(1), .name = "main", .path = "/w", .tab_count = 1 },
        },
    });
    _ = try server_messages.handleServerMessage(harness.client, try schema.decodeServer(list));
    try std.testing.expect(
        harness.client.view.workspace_list.indexOf(@enumFromInt(1)) != null,
    );
    try harness.settle();
}

test "an agent snapshot replaces the sidebar replica" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    var payload: [512]u8 = undefined;
    const snapshot = try schema.encodeAgentSnapshot(&payload, .{
        .revision = 1,
        .entries = &.{.{
            .pane_id = TestHarness.bootstrap_pane,
            .pane_generation = 1,
            .location = TestHarness.bootstrap_location,
            .pane_index = 1,
            .process_id = 42,
            .session_id = @splat(0),
            .workspace_label = "telar",
            .tab_label = "test-2",
            .session_title = "Improve agent sidebar",
            .title_source = .generated,
            .title_state = .ready,
            .cwd_label = "~/sandbox/telar",
            .provider = .claude,
            .status = .working,
            .source = .screen,
            .authority = .active,
            .confidence = 1,
            .sequence = 1,
            .observed_at_ms = 1,
            .expires_at_ms = 2,
        }},
    });
    _ = try server_messages.handleServerMessage(harness.client, try schema.decodeServer(snapshot));
    const agent = harness.client.view.sidebar_snapshot.find(.{
        .pane_id = TestHarness.bootstrap_pane,
        .pane_generation = 1,
    }).?;
    try std.testing.expectEqualStrings("telar", agent.workspaceLabel());
    try std.testing.expectEqualStrings("test-2", agent.tabLabel());
    try std.testing.expectEqualStrings("Improve agent sidebar", agent.sessionTitle());
    try std.testing.expectEqualStrings("~/sandbox/telar", agent.cwdLabel());
    try harness.settle();
}

test "a graphics revision break requests a graphics snapshot" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;

    var payload: [256]u8 = undefined;
    const begin = try schema.encodeGraphicsSnapshot(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 8,
        .phase = .begin,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(begin));
    const image = try schema.encodeGraphicsImage(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 9,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(image));
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .request_graphics_snapshot);
}

test "runtime stopping and stray history results" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    var payload: [128]u8 = undefined;
    const stopping = try schema.encodeRuntimeStopping(&payload);
    try std.testing.expectEqual(
        @as(?u8, 0),
        try server_messages.handleServerMessage(harness.client, try schema.decodeServer(stopping)),
    );

    const history = try schema.encodeHistoryResults(&payload, .{
        .request_id = @enumFromInt(2),
        .entries = &.{},
    });
    try std.testing.expectError(
        error.UnexpectedHistoryResults,
        server_messages.handleServerMessage(harness.client, try schema.decodeServer(history)),
    );
}

test "a pane clipboard write reaches the host terminal" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    const before = harness.sink.fullCount();
    var payload: [128]u8 = undefined;
    const clipboard = try schema.encodePaneClipboard(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .bytes = "copied",
    });
    _ = try server_messages.handleServerMessage(harness.client, try schema.decodeServer(clipboard));
    try std.testing.expect(harness.sink.fullCount() > before);
}

test "config reload outcomes that carry no new generation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;

    try client.handleConfigReloadEvent(.{ .unchanged = 42 });
    try std.testing.expectEqual(@as(i128, 42), client.reload.mtime_ns);

    var diagnostic: lua_config.Diagnostic = .{};
    diagnostic.set("bad config: {s}", .{"boom"});
    try client.handleConfigReloadEvent(.{ .failed = .{
        .diagnostic = diagnostic,
        .mtime_ns = 7,
    } });
    try std.testing.expectEqual(@as(i128, 7), client.reload.mtime_ns);
    try std.testing.expect(client.notification_tick_pending);
    try std.testing.expect(client.config_diagnostic.len != 0);
    try harness.settle();
}

test "input timer expiries with nothing pending are a no-op" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    try std.testing.expect(!try harness.client.handleInputTimeoutEvent({}));
    try std.testing.expect(!try harness.client.handleBindingTimeoutEvent({}));
    try std.testing.expect(!harness.client.input_timeout_pending);
    try std.testing.expect(!harness.client.binding_timeout_pending);
}

test "a capability expiry reconfigures the sidebar without a tab" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    try harness.client.handleCapabilityTimeoutEvent({});
    try harness.settle();
}

test "copy mode round trip: enter, select, copy, leave" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    var handler: InputHandler = .{ .client = client };
    try std.testing.expectEqual(keybind.Control.continue_routing, try handler.applyNativeAction(.enter_copy_mode));
    try std.testing.expect(client.mode == .copy);

    // While in copy mode, keys route to the selection, not the pane.
    try handler.key(try keybind.parseKey("v"));
    try handler.key(try keybind.parseKey("l"));
    try handler.key(try keybind.parseKey("enter"));
    try std.testing.expect(client.mode == .normal);
    try harness.settle();

    var buffer: [256]u8 = undefined;
    var copied = false;
    while (!copied) {
        switch (try harness.nextClientMessage(&buffer)) {
            .copy_selection => |selection| {
                try std.testing.expectEqual(TestHarness.bootstrap_pane, selection.pane_id);
                try std.testing.expectEqual(@as(u16, 1), selection.end_x);
                copied = true;
            },
            .set_pane_viewport, .pane_input => {},
            else => return error.UnexpectedClientMessage,
        }
    }
}

test "workspace rename separates prompt submission canonical commit and presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before_request = client.model.version();
    const pending_updates_before_request = client.presenter.pending_updates;

    client.beginWorkspaceRenamePrompt(TestHarness.bootstrap_location.workspace, "main");
    var handler: InputHandler = .{ .client = client };
    try handler.forward("x\r");

    try std.testing.expect(client.mode == .normal);
    try std.testing.expect(!client.view.hasNamePrompt());
    try std.testing.expectEqualStrings("", client.model.workspace.workspaceName());
    try std.testing.expectEqualDeep(version_before_request, client.model.version());
    try std.testing.expectEqual(pending_updates_before_request, client.presenter.pending_updates);
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
    try std.testing.expectEqual(pending_updates_before_request, client.presenter.pending_updates);

    try client.observeModel();

    try std.testing.expectEqual(pending_updates_before_request + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    const version_before_noop = client.model.version();
    const pending_updates_before_noop = client.presenter.pending_updates;
    try client.requests.add(@enumFromInt(90), .{
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
    try client.observeModel();

    try std.testing.expectEqualDeep(version_before_noop, client.model.version());
    try std.testing.expectEqual(pending_updates_before_noop, client.presenter.pending_updates);
}

test "pending workspace operation keeps the rename prompt without sending" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    try client.requests.add(@enumFromInt(90), .{
        .rename_workspace = TestHarness.bootstrap_location.workspace,
    });
    const next_request_id = client.next_request_id;
    const version_before_request = client.model.version();

    client.beginWorkspaceRenamePrompt(TestHarness.bootstrap_location.workspace, "main");
    var handler: InputHandler = .{ .client = client };
    try handler.forward("x\r");

    try std.testing.expect(client.mode == .prompt);
    try std.testing.expect(client.view.hasNamePrompt());
    try std.testing.expectEqual(next_request_id, client.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.outbox.len);
    try std.testing.expectEqualDeep(version_before_request, client.model.version());

    try handler.forward("\x1b");
    try std.testing.expect(client.mode == .normal);
}

test "tab rename separates prompt submission canonical commit and presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.requests = .{};
    const version_before_request = client.model.version();
    const pending_updates_before_request = client.presenter.pending_updates;

    client.beginTabRenamePrompt(TestHarness.bootstrap_location.tab_id, "main");
    var handler: InputHandler = .{ .client = client };
    try std.testing.expect(handler.capturesKeys());

    try handler.forward("x");
    try handler.forward("\r");
    try std.testing.expect(client.mode == .normal);
    try std.testing.expect(!client.view.hasNamePrompt());
    try std.testing.expectEqualStrings("main", client.model.workspace.activeConst().?.labelSlice());
    try std.testing.expectEqualDeep(version_before_request, client.model.version());
    try std.testing.expectEqual(pending_updates_before_request, client.presenter.pending_updates);
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .rename_tab);
    try std.testing.expectEqualStrings("mainx", message.rename_tab.label);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, message.rename_tab.location);

    var payload: [256]u8 = undefined;
    const renamed = try schema.encodeTabRenamed(&payload, .{
        .request_id = message.rename_tab.request_id,
        .location = message.rename_tab.location,
        .label = message.rename_tab.label,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(renamed));

    try std.testing.expectEqualStrings("mainx", client.model.workspace.activeConst().?.labelSlice());
    try std.testing.expectEqual(version_before_request.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_request.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before_request, client.presenter.pending_updates);

    try client.observeModel();

    try std.testing.expectEqual(pending_updates_before_request + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    const version_before_noop = client.model.version();
    const pending_updates_before_noop = client.presenter.pending_updates;
    try client.requests.add(@enumFromInt(90), .{ .rename_tab = TestHarness.bootstrap_location });
    const unchanged = try schema.encodeTabRenamed(&payload, .{
        .request_id = @enumFromInt(90),
        .location = TestHarness.bootstrap_location,
        .label = "mainx",
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(unchanged));
    try client.observeModel();

    try std.testing.expectEqualDeep(version_before_noop, client.model.version());
    try std.testing.expectEqual(pending_updates_before_noop, client.presenter.pending_updates);
}

test "pending tab operation keeps the rename prompt without sending" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.requests = .{};
    try client.requests.add(@enumFromInt(90), .{ .move_tab = TestHarness.bootstrap_location });
    const next_request_id = client.next_request_id;
    const version_before_request = client.model.version();

    client.beginTabRenamePrompt(TestHarness.bootstrap_location.tab_id, "main");
    var handler: InputHandler = .{ .client = client };
    try handler.forward("x\r");

    try std.testing.expect(client.mode == .prompt);
    try std.testing.expect(client.view.hasNamePrompt());
    try std.testing.expectEqual(next_request_id, client.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.outbox.len);
    try std.testing.expectEqualDeep(version_before_request, client.model.version());

    try handler.forward("\x1b");
    try std.testing.expect(client.mode == .normal);
}

test "escaping the prompt editor returns the mode to normal" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;

    client.beginWorkspaceCreatePrompt();
    try std.testing.expect(client.mode == .prompt);
    var handler: InputHandler = .{ .client = client };
    try handler.forward("\x1b");
    try std.testing.expect(client.mode == .normal);
    try std.testing.expect(!client.view.hasNamePrompt());
}
