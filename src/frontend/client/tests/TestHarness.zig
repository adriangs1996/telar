const TestHarness = @This();
const core = @import("telar-core");
const source_namespace = @import("support.zig");
const Client = @import("../Client.zig");
const std = @import("std");
const runtime_transport = @import("../entrypoints/runtime_io.zig");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const sidebar_animations = @import("../controllers/notifications/sidebar_animations.zig");
const notification_flow = @import("../controllers/notifications/notifications.zig");
const bar_updates = @import("../controllers/configuration/bar_updates.zig");
const server_messages = @import("../entrypoints/runtime_messages.zig");
const request_lifecycle = @import("../connection/request_lifecycle.zig");
const workspace_capability = @import("../../workspace/root.zig");
connection: core.transport.SocketChannel,
peer: core.transport.SocketChannel,
input_read: source_namespace.File,
input_write: source_namespace.File,
sink: source_namespace.Io.Writer.Discarding,
client: *Client,

pub fn init(harness: *TestHarness) !void {
    try harness.initWithAsyncOutput(false);
}

/// Example: `try harness.initWithAsyncOutput(true);`.
pub fn initWithAsyncOutput(harness: *TestHarness, async_output: bool) !void {
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
    harness.client = try Client.init(.{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .connection = &harness.connection,
        .input_file = harness.input_read,
        .writer = &harness.sink.writer,
        .async_output = async_output,
        .host_size = .{ .cols = 80, .rows = 24, .cell_width_px = 0, .cell_height_px = 0 },
        .options = .{ .arguments = &.{}, .cwd = "/", .endpoint = "" },
    });
    // Every frame goes through the scheduled draw task, so tests observe
    // pending state deterministically. The inline path has its own test.
    harness.client.presenter.pacer = .{ .burst = 0, .credits = 0, .input_grace = 0 };
}

pub fn deinit(harness: *TestHarness) void {
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
pub fn settle(harness: *TestHarness) !void {
    while (harness.client.runtime_transport.outbox.inFlight() or harness.client.runtime_transport.outbox.len != 0) {
        switch (try harness.client.select.await()) {
            .sent => |result| try runtime_transport.handleSent(harness.client, result),
            .draw => |result| try presentation_lifecycle.handleDraw(harness.client, result),
            .sidebar_animation_tick => |result| {
                _ = try sidebar_animations.handleTick(harness.client, result);
                try presentation_lifecycle.observe(harness.client);
            },
            .notification_tick => |result| {
                _ = try notification_flow.handleTick(harness.client, result);
                try presentation_lifecycle.observe(harness.client);
            },
            .bar_tick => |result| {
                try bar_updates.handleTick(harness.client, result);
                try presentation_lifecycle.observe(harness.client);
            },
            .bar_command => |completion| {
                try bar_updates.completeCommand(harness.client, completion);
                try presentation_lifecycle.observe(harness.client);
            },
            else => return error.UnexpectedEvent,
        }
    }
}

pub fn settleModelPresentation(harness: *TestHarness) !void {
    var target = harness.client.model.version();
    const graphics_target = harness.client.graphics_store.ingressVersion();
    const attachment_target = harness.client.view.kittyAttachments().ingressVersion();
    const view_interaction_target = harness.client.view.interactionVersion();
    const input_routing_target = harness.client.host_input.presentationVersion();
    while (!std.meta.eql(harness.client.presenter.presentation_state.prepared.model, target) or
        harness.client.presenter.presentation_state.prepared.graphics_ingress != graphics_target or
        harness.client.presenter.presentation_state.prepared.attachment_ingress != attachment_target or
        harness.client.presenter.presentation_state.prepared.presentation_ingress.view_interaction !=
            view_interaction_target or
        harness.client.presenter.presentation_state.prepared.presentation_ingress.input_routing !=
            input_routing_target)
    {
        switch (try harness.client.select.await()) {
            .draw => |result| try presentation_lifecycle.handleDraw(harness.client, result),
            .sent => |result| try runtime_transport.handleSent(harness.client, result),
            .media_tick => |result| try presentation_lifecycle.handleMediaTick(harness.client, result),
            .sidebar_animation_tick => |result| {
                _ = try sidebar_animations.handleTick(harness.client, result);
                try presentation_lifecycle.observe(harness.client);
                target = harness.client.model.version();
            },
            .notification_tick => |result| {
                _ = try notification_flow.handleTick(harness.client, result);
                try presentation_lifecycle.observe(harness.client);
                target = harness.client.model.version();
            },
            .bar_tick => |result| {
                try bar_updates.handleTick(harness.client, result);
                try presentation_lifecycle.observe(harness.client);
                target = harness.client.model.version();
            },
            .bar_command => |completion| {
                try bar_updates.completeCommand(harness.client, completion);
                try presentation_lifecycle.observe(harness.client);
                target = harness.client.model.version();
            },
            else => return error.UnexpectedEvent,
        }
    }
}

/// Receives the next message the client sent to the runtime.
pub fn nextClientMessage(harness: *TestHarness, buffer: []u8) !source_namespace.schema.ClientMessage {
    const payload = try harness.peer.receive(std.testing.io, buffer);
    return source_namespace.schema.decodeClient(payload);
}

pub fn nextAttachmentRequest(harness: *TestHarness, pane_id: source_namespace.schema.PaneId, buffer: []u8) !source_namespace.schema.RequestId {
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

pub fn discoverAndRequestAttachment(harness: *TestHarness, pane_id: source_namespace.schema.PaneId, buffer: []u8) !source_namespace.schema.RequestId {
    const snapshot = try source_namespace.schema.encodeTabSnapshot(buffer, .{
        .request_id = @enumFromInt(3),
        .location = bootstrap_location,
        .panes = &.{
            .{ .pane_id = bootstrap_pane, .lifecycle = .running },
            .{ .pane_id = pane_id, .lifecycle = .running },
        },
    });
    _ = try server_messages.handleServerMessage(harness.client, try source_namespace.schema.decodeServer(snapshot));
    try harness.settle();

    return harness.nextAttachmentRequest(pane_id, buffer);
}

pub const bootstrap_location: source_namespace.schema.TabLocation = .{
    .workspace = .{ .workspace = @enumFromInt(1) },
    .tab_id = @enumFromInt(1),
};
pub const bootstrap_pane: source_namespace.schema.PaneId = @enumFromInt(10);

/// Answers the initial open request through the real entrypoint, leaving
/// the client with one attached pane and its two snapshot requests (ids
/// 2 and 3) delivered to the peer.
pub fn bootstrap(harness: *TestHarness) !void {
    try std.testing.expectEqual(source_namespace.initial_request_id, try request_lifecycle.registerInitial(harness.client));
    var payload: [128]u8 = undefined;
    const opened = try source_namespace.schema.encodePaneOpened(&payload, .{
        .request_id = source_namespace.initial_request_id,
        .pane_id = bootstrap_pane,
        .location = bootstrap_location,
        .created = true,
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try server_messages.handleServerMessage(harness.client, try source_namespace.schema.decodeServer(opened)),
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

pub fn addTab(harness: *TestHarness, tab_id: source_namespace.schema.TabId, pane_id: source_namespace.schema.PaneId) !source_namespace.schema.TabLocation {
    const location: source_namespace.schema.TabLocation = .{
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

pub fn addInactiveTab(harness: *TestHarness, tab_id: source_namespace.schema.TabId, pane_id: source_namespace.schema.PaneId) !source_namespace.schema.TabLocation {
    const location = try harness.addTab(tab_id, pane_id);
    const tab = harness.client.model.workspace.find(tab_id).?;
    workspace_capability.tabs.Model.detachAll(tab);
    try harness.client.graphics_store.setPaneVisible(pane_id, false);
    try std.testing.expect(harness.client.model.workspace.select(bootstrap_location.tab_id));

    return location;
}

pub fn allowTabSelection(harness: *TestHarness) !void {
    const continuation = request_lifecycle.consume(harness.client, @enumFromInt(3)) orelse
        return error.MissingBootstrapTabSnapshot;
    try std.testing.expect(continuation == .tab_snapshot);
}
