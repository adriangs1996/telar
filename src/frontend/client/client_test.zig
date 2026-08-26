//! Substituted-platform tests for the Client: a real Client over a
//! socketpair standing in for the runtime socket, a pipe for the tty's
//! read handle, and a discarding writer for the host terminal.

const std = @import("std");
const core = @import("telar-core");
const input_capability = @import("../input/root.zig");
const lua_config = @import("../config/root.zig");
const keybind = input_capability.keybind;

const Io = std.Io;
const File = Io.File;
const schema = core.schema;

const Client = @import("client.zig");
const InputHandler = @import("input_handler.zig");
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

    /// Receives the next message the client sent to the runtime.
    fn nextClientMessage(harness: *TestHarness, buffer: []u8) !schema.ClientMessage {
        const payload = try harness.peer.receive(std.testing.io, buffer);
        return schema.decodeClient(payload);
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
        try harness.client.requests.add(initial_request_id, .initial_open);
        var payload: [128]u8 = undefined;
        const opened = try schema.encodePaneOpened(&payload, .{
            .request_id = initial_request_id,
            .pane_id = bootstrap_pane,
            .location = bootstrap_location,
            .created = true,
        });
        try std.testing.expectEqual(
            @as(?u8, null),
            try harness.client.handleServerMessage(try schema.decodeServer(opened)),
        );
        try harness.settle();
        var buffer: [256]u8 = undefined;
        const first = try harness.nextClientMessage(&buffer);
        try std.testing.expect(first == .request_workspace_snapshot);
        const second = try harness.nextClientMessage(&buffer);
        try std.testing.expect(second == .request_tab_snapshot);
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

    try std.testing.expectEqual(@as(usize, 1), harness.client.tabs.count);
    const pane = harness.client.tabs.findPane(TestHarness.bootstrap_pane).?;
    try std.testing.expect(pane.attached);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, harness.client.reported_focus);
}

test "a tab snapshot attaches every pane the client does not hold" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();

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
        try harness.client.handleServerMessage(try schema.decodeServer(snapshot)),
    );
    try harness.settle();

    const pane = harness.client.tabs.findPane(discovered).?;
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
        harness.client.handleServerMessage(try schema.decodeServer(snapshot)),
    );
}

test "a workspace snapshot reconciles the tab list" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();

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
        try harness.client.handleServerMessage(try schema.decodeServer(snapshot)),
    );
    try harness.settle();

    try std.testing.expectEqual(@as(usize, 2), harness.client.tabs.count);
    try std.testing.expect(harness.client.tabs.find(@enumFromInt(2)) != null);
    // The active tab keeps its identity through reconciliation.
    try std.testing.expectEqual(
        TestHarness.bootstrap_location.tab_id,
        harness.client.tabs.active().?.location.tab_id,
    );
}

test "resync required requests one workspace snapshot and coalesces repeats" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.tabs.workspace = TestHarness.bootstrap_location.workspace;

    try client.handleResyncRequired(.{
        .workspace = TestHarness.bootstrap_location.workspace,
        .workspace_closed = false,
    });
    try client.handleResyncRequired(.{
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

    const model = &client.tabs.active().?.model;
    model.find(TestHarness.bootstrap_pane).?.input_modes.focus_events = true;
    try client.syncPaneFocus(model);
    try harness.settle();

    try std.testing.expect(client.reported_focus_events);
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .pane_input);
    try std.testing.expectEqualStrings("\x1b[I", message.pane_input.bytes);
}

test "a split reply lands in the tab that asked for it" {
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
    } });
    var payload: [128]u8 = undefined;
    const opened = try schema.encodePaneOpened(&payload, .{
        .request_id = @enumFromInt(4),
        .pane_id = split_pane,
        .location = TestHarness.bootstrap_location,
        .created = false,
    });
    _ = try client.handleServerMessage(try schema.decodeServer(opened));
    try harness.settle();
    try std.testing.expect(client.tabs.findPane(split_pane) != null);
}

test "an attach reply marks the discovered pane attached" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

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
    _ = try client.handleServerMessage(try schema.decodeServer(snapshot));
    try std.testing.expect(!client.tabs.findPane(discovered).?.attached);

    // The attach request enqueued by the snapshot got id 4.
    const opened = try schema.encodePaneOpened(&payload, .{
        .request_id = @enumFromInt(4),
        .pane_id = discovered,
        .location = TestHarness.bootstrap_location,
        .created = false,
    });
    _ = try client.handleServerMessage(try schema.decodeServer(opened));
    try harness.settle();
    try std.testing.expect(client.tabs.findPane(discovered).?.attached);
}

test "a created workspace replaces the tabs wholesale" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

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
    _ = try client.handleServerMessage(try schema.decodeServer(opened));
    try harness.settle();

    try std.testing.expectEqualDeep(
        @as(?schema.WorkspaceLocation, new_location.workspace),
        client.tabs.workspace,
    );
    try std.testing.expect(client.tabs.findPane(@enumFromInt(30)) != null);
    try std.testing.expect(client.tabs.findPane(TestHarness.bootstrap_pane) == null);
}

test "tab lifecycle: created, renamed, moved, closed" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const workspace = TestHarness.bootstrap_location.workspace;
    const second_location: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    var payload: [256]u8 = undefined;

    // Created: the new tab becomes active and the old one detaches.
    try client.requests.add(@enumFromInt(4), .{ .create_tab = workspace });
    const created = try schema.encodeTabCreated(&payload, .{
        .request_id = @enumFromInt(4),
        .location = second_location,
        .position = 1,
        .label = "second",
        .root_pane_id = @enumFromInt(20),
    });
    _ = try client.handleServerMessage(try schema.decodeServer(created));
    try harness.settle();
    try std.testing.expectEqual(@as(usize, 2), client.tabs.count);
    try std.testing.expectEqual(second_location.tab_id, client.tabs.active().?.location.tab_id);
    var buffer: [256]u8 = undefined;
    const detached = try harness.nextClientMessage(&buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, detached.detach_pane.pane_id);

    // Renamed.
    try client.requests.add(@enumFromInt(5), .{ .rename_tab = second_location });
    const renamed = try schema.encodeTabRenamed(&payload, .{
        .request_id = @enumFromInt(5),
        .location = second_location,
        .label = "renamed",
    });
    _ = try client.handleServerMessage(try schema.decodeServer(renamed));
    try std.testing.expectEqualStrings(
        "renamed",
        client.tabs.find(second_location.tab_id).?.labelSlice(),
    );

    // Moved to the front.
    try client.requests.add(@enumFromInt(6), .{ .move_tab = second_location });
    const moved = try schema.encodeTabMoved(&payload, .{
        .request_id = @enumFromInt(6),
        .location = second_location,
        .position = 0,
    });
    _ = try client.handleServerMessage(try schema.decodeServer(moved));
    try std.testing.expectEqual(@as(?usize, 0), client.tabs.indexOf(second_location.tab_id));

    // Requested close of the active tab: the survivor becomes active and a
    // fresh snapshot for it is requested.
    try client.requests.add(@enumFromInt(7), .{ .close_tab = second_location });
    const closed = try schema.encodeTabClosed(&payload, .{
        .request_id = @enumFromInt(7),
        .location = second_location,
        .workspace_closed = false,
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try client.handleServerMessage(try schema.decodeServer(closed)),
    );
    try harness.settle();
    try std.testing.expectEqual(@as(usize, 1), client.tabs.count);
    try std.testing.expectEqual(
        TestHarness.bootstrap_location.tab_id,
        client.tabs.active().?.location.tab_id,
    );

    // An unknown close request is rejected.
    const unexpected = try schema.encodeTabClosed(&payload, .{
        .request_id = @enumFromInt(99),
        .location = second_location,
        .workspace_closed = false,
    });
    try std.testing.expectError(
        error.UnexpectedTabClosed,
        client.handleServerMessage(try schema.decodeServer(unexpected)),
    );
}

test "closing the last workspace exits the client" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();

    var payload: [128]u8 = undefined;
    const closed = try schema.encodeTabClosed(&payload, .{
        .request_id = .none,
        .location = TestHarness.bootstrap_location,
        .workspace_closed = true,
    });
    try std.testing.expectEqual(
        @as(?u8, 0),
        try harness.client.handleServerMessage(try schema.decodeServer(closed)),
    );
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
        try harness.client.handleServerMessage(try schema.decodeServer(resync)),
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
    _ = try client.handleServerMessage(try schema.decodeServer(patch));
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
    _ = try client.handleServerMessage(try schema.decodeServer(snapshot));
    try std.testing.expectEqual(
        @as(u64, 5),
        client.tabs.findPane(TestHarness.bootstrap_pane).?.applied_frame_id,
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
    _ = try harness.client.handleServerMessage(try schema.decodeServer(cwd));
    try harness.settle();
    try std.testing.expectEqualStrings(
        "/work/telar",
        harness.client.tabs.findPane(TestHarness.bootstrap_pane).?.cwdSlice(),
    );
}

test "an unrequested pane exit removes the pane and its client state" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.mode = .{ .copy = .init(TestHarness.bootstrap_pane, .{ .x = 0, .y = 0 }, 0) };

    var payload: [128]u8 = undefined;
    const exited = try schema.encodePaneExited(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .kind = .exited,
        .value = 0,
    });
    _ = try client.handleServerMessage(try schema.decodeServer(exited));
    try harness.settle();

    try std.testing.expect(client.tabs.findPane(TestHarness.bootstrap_pane) == null);
    try std.testing.expect(client.mode == .normal);
    try std.testing.expectEqual(@as(?schema.PaneId, null), client.reported_focus);
    try std.testing.expect(client.notification_tick_pending);
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
    _ = try client.handleServerMessage(try schema.decodeServer(failed));
    try harness.settle();
    try std.testing.expect(client.notification_tick_pending);

    const unknown = try schema.encodeRequestFailed(&payload, .{
        .request_id = @enumFromInt(99),
        .code = .pane_not_found,
        .message = "no such request",
    });
    try std.testing.expectError(
        error.UnexpectedRequestFailure,
        client.handleServerMessage(try schema.decodeServer(unknown)),
    );
}

test "runtime notifications and delivery failures reach the toasts" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;

    var payload: [256]u8 = undefined;
    const notification = try schema.encodeNotification(&payload, .{ .title = "hello" });
    _ = try client.handleServerMessage(try schema.decodeServer(notification));
    try std.testing.expect(client.notification_tick_pending);

    try client.requests.add(@enumFromInt(2), .notification);
    const shown = try schema.encodeNotificationShown(&payload, .{
        .request_id = @enumFromInt(2),
        .delivered_clients = 0,
    });
    _ = try client.handleServerMessage(try schema.decodeServer(shown));

    const unexpected = try schema.encodeNotificationShown(&payload, .{
        .request_id = @enumFromInt(9),
        .delivered_clients = 1,
    });
    try std.testing.expectError(
        error.UnexpectedNotificationReply,
        client.handleServerMessage(try schema.decodeServer(unexpected)),
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
    _ = try client.handleServerMessage(try schema.decodeServer(status));
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
    _ = try harness.client.handleServerMessage(try schema.decodeServer(metrics));
    try std.testing.expect(harness.client.draw_pending);
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
    _ = try harness.client.handleServerMessage(try schema.decodeServer(list));
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
            .process_id = 42,
            .session_id = @splat(0),
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
    _ = try harness.client.handleServerMessage(try schema.decodeServer(snapshot));
    try std.testing.expect(harness.client.view.sidebar_snapshot.find(.{
        .pane_id = TestHarness.bootstrap_pane,
        .pane_generation = 1,
    }) != null);
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
    _ = try client.handleServerMessage(try schema.decodeServer(begin));
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
    _ = try client.handleServerMessage(try schema.decodeServer(image));
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
        try harness.client.handleServerMessage(try schema.decodeServer(stopping)),
    );

    const history = try schema.encodeHistoryResults(&payload, .{
        .request_id = @enumFromInt(2),
        .entries = &.{},
    });
    try std.testing.expectError(
        error.UnexpectedHistoryResults,
        harness.client.handleServerMessage(try schema.decodeServer(history)),
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
    _ = try harness.client.handleServerMessage(try schema.decodeServer(clipboard));
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

test "the name prompt captures keys until submit returns to normal" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    client.beginTabRenamePrompt(TestHarness.bootstrap_location.tab_id, "main");
    var handler: InputHandler = .{ .client = client };
    try std.testing.expect(handler.capturesKeys());

    try handler.forward("x");
    try handler.forward("\r");
    try std.testing.expect(client.mode == .normal);
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .rename_tab);
    try std.testing.expectEqualStrings("mainx", message.rename_tab.label);
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
