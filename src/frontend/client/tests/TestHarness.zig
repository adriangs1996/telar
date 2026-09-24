const localsocket = @import("localsocket");
const data = @import("model");
const core = @import("telar-core");
const client_module = @import("telar-client");
const TerminalAdapter = @import("../TerminalAdapter.zig");
const std = @import("std");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const host_effects = @import("../host/host_effects.zig");
const view_chrome = @import("../presentation/view_chrome.zig");
const TestHarness = @This();

connection: localsocket.SocketChannel,
peer: localsocket.SocketChannel,
input_read: std.Io.File,
input_write: std.Io.File,
sink: std.Io.Writer.Discarding,
client: *client_module.Client,
terminal: *TerminalAdapter,

pub fn init(self: *TestHarness) !void {
    try self.initWithAsyncOutput(false);
}

/// Example: `try harness.initWithAsyncOutput(true);`.
pub fn initWithAsyncOutput(self: *TestHarness, async_output: bool) !void {
    try self.initWithOptions(async_output, .{ .arguments = &.{}, .cwd = "/", .endpoint = "" });
}

/// Starts the client with explicit options, such as a loaded configuration
/// generation the client adopts.
/// Example: `try harness.initWithOptions(false, options);`.
pub fn initWithOptions(self: *TestHarness, async_output: bool, options: client_module.Options) !void {
    var sockets: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets) != 0) {
        return error.SocketPairFailed;
    }
    self.connection = .init(.{ .socket = .{
        .handle = sockets[0],
        .address = .{ .ip4 = .loopback(0) },
    } });
    self.peer = .init(.{ .socket = .{
        .handle = sockets[1],
        .address = .{ .ip4 = .loopback(0) },
    } });
    var pipe_fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) {
        return error.PipeFailed;
    }
    self.input_read = .{ .handle = pipe_fds[0], .flags = .{ .nonblocking = false } };
    self.input_write = .{ .handle = pipe_fds[1], .flags = .{ .nonblocking = false } };
    self.sink = .init(&.{});
    const terminal = try TerminalAdapter.init(.{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .connection = &self.connection,
        .input_file = self.input_read,
        .writer = &self.sink.writer,
        .async_output = async_output,
        .host_size = .{ .cols = 80, .rows = 24, .cell_width_px = 0, .cell_height_px = 0 },
        .options = options,
    });
    self.client = &terminal.app;
    self.terminal = terminal;
    // Every frame goes through the scheduled draw task, so tests observe
    // pending state deterministically. The inline path has its own test.
    terminal.presenter.pacer = .{ .burst = 0, .credits = 0, .input_grace = 0 };
}

pub fn deinit(self: *TestHarness) void {
    const io = std.testing.io;
    // EOF unblocks a pending input read so task cancellation never has
    // to wait on the pipe.
    self.input_write.close(io);
    self.terminal.deinit();
    self.peer.deinit(io);
    self.connection.deinit(io);
    self.input_read.close(io);
}

/// Drives the real dispatch until the outbox is drained, so a test
/// observes exactly what the runtime peer would receive.
pub fn settle(self: *TestHarness) !void {
    while (self.client.model.to_runtime.inFlight() or self.client.model.to_runtime.len != 0) {
        try host_effects.deliver(self.terminal);
        switch (try self.terminal.inbox.receive()) {
            .draw => |result| try presentation_lifecycle.handleDraw(self.terminal, result),
            .client => |message| switch (message) {
                .sent, .sidebar_animation_tick, .notification_tick, .bar_tick, .bar_command, .path_completion => {
                    const observes = message != .sent;
                    _ = try self.client.update(message);
                    try self.deliverHostEffects();
                    if (observes) {
                        try presentation_lifecycle.observe(self.terminal);
                    }
                },
                else => return error.UnexpectedEvent,
            },
            else => return error.UnexpectedEvent,
        }
    }

    try data.model_invariants.check(&self.client.model);
}

/// Draws the chrome facts and delivers the host requests a direct client
/// call left, as the event loop does after every event.
/// Example: `try harness.deliverHostEffects();`
pub fn deliverHostEffects(self: *TestHarness) !void {
    try view_chrome.refresh(self.terminal);
    try host_effects.deliver(self.terminal);
    try data.model_invariants.check(&self.client.model);
}

pub fn settleModelPresentation(self: *TestHarness) !void {
    var target = self.client.model.version();
    const graphics_target = self.terminal.graphics_store.ingressVersion();
    const attachment_target = self.terminal.view.kittyAttachments().ingressVersion();
    const view_interaction_target = self.terminal.view.interactionVersion();
    const input_routing_target = self.terminal.host_input.presentationVersion();
    while (!std.meta.eql(self.terminal.presenter.presentation_state.prepared.model, target) or
        self.terminal.presenter.presentation_state.prepared.graphics_ingress != graphics_target or
        self.terminal.presenter.presentation_state.prepared.attachment_ingress != attachment_target or
        self.terminal.presenter.presentation_state.prepared.presentation_ingress.view_interaction !=
            view_interaction_target or
        self.terminal.presenter.presentation_state.prepared.presentation_ingress.input_routing !=
            input_routing_target)
    {
        switch (try self.terminal.inbox.receive()) {
            .draw => |result| try presentation_lifecycle.handleDraw(self.terminal, result),
            .media_tick => |result| try presentation_lifecycle.handleMediaTick(self.terminal, result),
            .client => |message| switch (message) {
                .sent => |result| {
                    try client_module.runtime_io.completeRuntimeSend(&self.client.model, result);
                    try host_effects.deliver(self.terminal);
                },
                .sidebar_animation_tick, .notification_tick, .bar_tick, .bar_command, .path_completion => {
                    _ = try self.client.update(message);
                    try host_effects.deliver(self.terminal);
                    try presentation_lifecycle.observe(self.terminal);
                    target = self.client.model.version();
                },
                else => return error.UnexpectedEvent,
            },
            else => return error.UnexpectedEvent,
        }
    }
}

/// Receives the next message the client sent to the runtime, first starting
/// the write a direct client call left queued, as the event loop would.
/// Example: `const message = try harness.nextClientMessage(&buffer);`
pub fn nextClientMessage(self: *TestHarness, buffer: []u8) !core.ClientMessage {
    try host_effects.deliver(self.terminal);

    return self.receiveClientMessage(buffer);
}

/// Receives the next message already on the runtime's side of the socket.
/// It touches only the peer, so a concurrent reader may call it while the
/// test thread drives the client with `settle`.
/// Example: `const message = try harness.receiveClientMessage(&buffer);`
pub fn receiveClientMessage(self: *TestHarness, buffer: []u8) !core.ClientMessage {
    const payload = try self.peer.receive(std.testing.io, buffer);
    return core.decodeClient(payload);
}

pub fn nextAttachmentRequest(self: *TestHarness, pane_id: core.PaneId, buffer: []u8) !core.RequestId {
    while (true) {
        switch (try self.nextClientMessage(buffer)) {
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

pub fn discoverAndRequestAttachment(self: *TestHarness, pane_id: core.PaneId, buffer: []u8) !core.RequestId {
    const snapshot = try core.encodeTabSnapshot(buffer, .{
        .request_id = @enumFromInt(3),
        .location = bootstrap_location,
        .panes = &.{
            .{ .pane_id = bootstrap_pane, .lifecycle = .running },
            .{ .pane_id = pane_id, .lifecycle = .running },
        },
    });
    _ = try client_module.runtime_messages.handleServerMessage(self.client, try core.decodeServer(snapshot));
    try self.settle();

    return self.nextAttachmentRequest(pane_id, buffer);
}

pub const bootstrap_location: core.TabLocation = .{
    .workspace = .{ .workspace = @enumFromInt(1) },
    .tab_id = @enumFromInt(1),
};
pub const bootstrap_pane: core.PaneId = @enumFromInt(10);

/// Answers the initial open request through the real entrypoint, leaving
/// the client with one attached pane and its two snapshot requests (ids
/// 2 and 3) delivered to the peer.
pub fn bootstrap(self: *TestHarness) !void {
    try self.client.model.request_lifecycle.tracker.add(
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
        try client_module.runtime_messages.handleServerMessage(self.client, try core.decodeServer(opened)),
    );
    try self.settle();
    var buffer: [256]u8 = undefined;
    const first = try self.nextClientMessage(&buffer);
    try std.testing.expect(first == .request_workspace_snapshot);
    const second = try self.nextClientMessage(&buffer);
    try std.testing.expect(second == .request_tab_snapshot);
    try presentation_lifecycle.observe(self.terminal);
    try self.settleModelPresentation();
}

pub fn addTab(self: *TestHarness, tab_id: core.TabId, pane_id: core.PaneId) !core.TabLocation {
    const location: core.TabLocation = .{
        .workspace = bootstrap_location.workspace,
        .tab_id = tab_id,
    };

    _ = try data.tab_creation.add(&self.client.model, .{
        .location = location,
        .position = @intCast(self.client.model.tabs.count),
        .label = "second",
        .root_pane_id = pane_id,
    }, .{ .cols = 80, .rows = 24 });

    return location;
}

pub fn addInactiveTab(self: *TestHarness, tab_id: core.TabId, pane_id: core.PaneId) !core.TabLocation {
    const location = try self.addTab(tab_id, pane_id);
    var panes = self.client.model.panes.iterate(tab_id);
    while (panes.next()) |pane| {
        pane.attached = false;
        pane.pending_frame_id = 0;
    }
    try self.terminal.graphics_store.setPaneVisible(pane_id, false);
    try std.testing.expect(data.tab_selection.select(&self.client.model, bootstrap_location.tab_id));

    return location;
}

pub fn allowTabSelection(self: *TestHarness) !void {
    const continuation = self.client.model.request_lifecycle.tracker.take(@enumFromInt(3)) orelse
        return error.MissingBootstrapTabSnapshot;
    try std.testing.expect(continuation == .tab_snapshot);
}
