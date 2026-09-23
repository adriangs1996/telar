const data = @import("model");
const core = @import("telar-core");
const client_module = @import("telar-client");
const TerminalClient = @import("../TerminalClient.zig");
const std = @import("std");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const TestHarness = @This();

connection: core.SocketChannel,
peer: core.SocketChannel,
input_read: std.Io.File,
input_write: std.Io.File,
sink: std.Io.Writer.Discarding,
client: *client_module.AttachedClient,

pub fn init(harness: *TestHarness) !void {
    try harness.initWithAsyncOutput(false);
}

/// Example: `try harness.initWithAsyncOutput(true);`.
pub fn initWithAsyncOutput(harness: *TestHarness, async_output: bool) !void {
    try harness.initWithOptions(async_output, .{ .arguments = &.{}, .cwd = "/", .endpoint = "" });
}

/// Starts the client with explicit options, such as a loaded configuration
/// generation the client adopts.
/// Example: `try harness.initWithOptions(false, options);`.
pub fn initWithOptions(harness: *TestHarness, async_output: bool, options: client_module.Options) !void {
    var sockets: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets) != 0) {
        return error.SocketPairFailed;
    }
    harness.connection = .init(.{ .socket = .{
        .handle = sockets[0],
        .address = .{ .ip4 = .loopback(0) },
    } });
    harness.peer = .init(.{ .socket = .{
        .handle = sockets[1],
        .address = .{ .ip4 = .loopback(0) },
    } });
    var pipe_fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) {
        return error.PipeFailed;
    }
    harness.input_read = .{ .handle = pipe_fds[0], .flags = .{ .nonblocking = false } };
    harness.input_write = .{ .handle = pipe_fds[1], .flags = .{ .nonblocking = false } };
    harness.sink = .init(&.{});
    const terminal = try TerminalClient.init(.{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .connection = &harness.connection,
        .input_file = harness.input_read,
        .writer = &harness.sink.writer,
        .async_output = async_output,
        .host_size = .{ .cols = 80, .rows = 24, .cell_width_px = 0, .cell_height_px = 0 },
        .options = options,
    });
    harness.client = &terminal.app;
    // Every frame goes through the scheduled draw task, so tests observe
    // pending state deterministically. The inline path has its own test.
    terminal.presenter.pacer = .{ .burst = 0, .credits = 0, .input_grace = 0 };
}

pub fn deinit(harness: *TestHarness) void {
    const io = std.testing.io;
    // EOF unblocks a pending input read so task cancellation never has
    // to wait on the pipe.
    harness.input_write.close(io);
    TerminalClient.of(harness.client).deinit();
    harness.peer.deinit(io);
    harness.connection.deinit(io);
    harness.input_read.close(io);
}

/// Drives the real dispatch until the outbox is drained, so a test
/// observes exactly what the runtime peer would receive.
pub fn settle(harness: *TestHarness) !void {
    while (harness.client.runtime_transport.outbox.inFlight() or harness.client.runtime_transport.outbox.len != 0) {
        switch (try TerminalClient.of(harness.client).inbox.receive()) {
            .sent => |result| try harness.client.completeRuntimeSend(result),
            .draw => |result| try presentation_lifecycle.handleDraw(harness.client, result),
            .sidebar_animation_tick => |result| {
                _ = try harness.client.completeSidebarAnimationTick(result);
                try presentation_lifecycle.observe(harness.client);
            },
            .notification_tick => |result| {
                _ = try harness.client.completeNotificationTick(result);
                try presentation_lifecycle.observe(harness.client);
            },
            .bar_tick => |result| {
                try client_module.operations.bar_updates.handleTick(harness.client, result);
                try presentation_lifecycle.observe(harness.client);
            },
            .bar_command => |completion| {
                try client_module.operations.bar_updates.completeCommand(harness.client, completion);
                try presentation_lifecycle.observe(harness.client);
            },
            .path_completion => |completion| {
                try harness.client.completePathCompletion(completion);
                try presentation_lifecycle.observe(harness.client);
            },
            else => return error.UnexpectedEvent,
        }
    }
}

pub fn settleModelPresentation(harness: *TestHarness) !void {
    var target = harness.client.model.version();
    const graphics_target = TerminalClient.of(harness.client).graphics_store.ingressVersion();
    const attachment_target = TerminalClient.of(harness.client).view.kittyAttachments().ingressVersion();
    const view_interaction_target = TerminalClient.of(harness.client).view.interactionVersion();
    const input_routing_target = TerminalClient.of(harness.client).host_input.presentationVersion();
    while (!std.meta.eql(TerminalClient.of(harness.client).presenter.presentation_state.prepared.model, target) or
        TerminalClient.of(harness.client).presenter.presentation_state.prepared.graphics_ingress != graphics_target or
        TerminalClient.of(harness.client).presenter.presentation_state.prepared.attachment_ingress != attachment_target or
        TerminalClient.of(harness.client).presenter.presentation_state.prepared.presentation_ingress.view_interaction !=
            view_interaction_target or
        TerminalClient.of(harness.client).presenter.presentation_state.prepared.presentation_ingress.input_routing !=
            input_routing_target)
    {
        switch (try TerminalClient.of(harness.client).inbox.receive()) {
            .draw => |result| try presentation_lifecycle.handleDraw(harness.client, result),
            .sent => |result| try harness.client.completeRuntimeSend(result),
            .media_tick => |result| try presentation_lifecycle.handleMediaTick(harness.client, result),
            .sidebar_animation_tick => |result| {
                _ = try harness.client.completeSidebarAnimationTick(result);
                try presentation_lifecycle.observe(harness.client);
                target = harness.client.model.version();
            },
            .notification_tick => |result| {
                _ = try harness.client.completeNotificationTick(result);
                try presentation_lifecycle.observe(harness.client);
                target = harness.client.model.version();
            },
            .bar_tick => |result| {
                try client_module.operations.bar_updates.handleTick(harness.client, result);
                try presentation_lifecycle.observe(harness.client);
                target = harness.client.model.version();
            },
            .bar_command => |completion| {
                try client_module.operations.bar_updates.completeCommand(harness.client, completion);
                try presentation_lifecycle.observe(harness.client);
                target = harness.client.model.version();
            },
            .path_completion => |completion| {
                try harness.client.completePathCompletion(completion);
                try presentation_lifecycle.observe(harness.client);
                target = harness.client.model.version();
            },
            else => return error.UnexpectedEvent,
        }
    }
}

/// Receives the next message the client sent to the runtime.
pub fn nextClientMessage(harness: *TestHarness, buffer: []u8) !core.ClientMessage {
    const payload = try harness.peer.receive(std.testing.io, buffer);
    return core.decodeClient(payload);
}

pub fn nextAttachmentRequest(harness: *TestHarness, pane_id: core.PaneId, buffer: []u8) !core.RequestId {
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

pub fn discoverAndRequestAttachment(harness: *TestHarness, pane_id: core.PaneId, buffer: []u8) !core.RequestId {
    const snapshot = try core.encodeTabSnapshot(buffer, .{
        .request_id = @enumFromInt(3),
        .location = bootstrap_location,
        .panes = &.{
            .{ .pane_id = bootstrap_pane, .lifecycle = .running },
            .{ .pane_id = pane_id, .lifecycle = .running },
        },
    });
    _ = try harness.client.handleServerMessage(try core.decodeServer(snapshot));
    try harness.settle();

    return harness.nextAttachmentRequest(pane_id, buffer);
}

pub const bootstrap_location: core.TabLocation = .{
    .workspace = .{ .workspace = @enumFromInt(1) },
    .tab_id = @enumFromInt(1),
};
pub const bootstrap_pane: core.PaneId = @enumFromInt(10);

/// Answers the initial open request through the real entrypoint, leaving
/// the client with one attached pane and its two snapshot requests (ids
/// 2 and 3) delivered to the peer.
pub fn bootstrap(harness: *TestHarness) !void {
    try harness.client.request_lifecycle.tracker.add(
        client_module.initial_request_id,
        .{
            .initial_open = .{},
        },
    );
    var payload: [128]u8 = undefined;
    const opened = try core.encodePaneOpened(&payload, .{
        .request_id = client_module.initial_request_id,
        .pane_id = bootstrap_pane,
        .location = bootstrap_location,
        .created = true,
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try harness.client.handleServerMessage(try core.decodeServer(opened)),
    );
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const first = try harness.nextClientMessage(&buffer);
    try std.testing.expect(first == .request_workspace_snapshot);
    const second = try harness.nextClientMessage(&buffer);
    try std.testing.expect(second == .request_tab_snapshot);
    try presentation_lifecycle.observe(harness.client);
    try harness.settleModelPresentation();
}

pub fn addTab(harness: *TestHarness, tab_id: core.TabId, pane_id: core.PaneId) !core.TabLocation {
    const location: core.TabLocation = .{
        .workspace = bootstrap_location.workspace,
        .tab_id = tab_id,
    };

    _ = try data.tab_creation.add(&harness.client.model, .{
        .location = location,
        .position = @intCast(harness.client.model.tabs.count),
        .label = "second",
        .root_pane_id = pane_id,
    }, .{ .cols = 80, .rows = 24 });

    return location;
}

pub fn addInactiveTab(harness: *TestHarness, tab_id: core.TabId, pane_id: core.PaneId) !core.TabLocation {
    const location = try harness.addTab(tab_id, pane_id);
    var panes = harness.client.model.panes.iterate(tab_id);
    while (panes.next()) |pane| {
        pane.attached = false;
        pane.pending_frame_id = 0;
    }
    try TerminalClient.of(harness.client).graphics_store.setPaneVisible(pane_id, false);
    try std.testing.expect(data.tab_selection.select(&harness.client.model, bootstrap_location.tab_id));

    return location;
}

pub fn allowTabSelection(harness: *TestHarness) !void {
    const continuation = harness.client.request_lifecycle.tracker.take(@enumFromInt(3)) orelse
        return error.MissingBootstrapTabSnapshot;
    try std.testing.expect(continuation == .tab_snapshot);
}
