//! One shared client over a real socket pair, driven the way an adapter
//! drives it but with no window: jobs run through the shared runner, host
//! requests are recorded, and a presentation completes the moment it is
//! prepared. The runtime's side of the socket is `peer`, so a test sends
//! what the runtime would and reads what the client sent.
const keyinput = @import("keyinput");
const localsocket = @import("localsocket");
const mailbox = @import("mailbox");
const data = @import("model");
const core = @import("telar-core");
const client_module = @import("telar-client");
const std = @import("std");
const RetainedGraphics = @import("RetainedGraphics.zig");
const ClientHarness = @This();

pub const Event = union(enum) {
    client: client_module.Message,
};

pub const Inbox = mailbox.GenericInbox(Event);

pub const bootstrap_location: core.TabLocation = .{
    .workspace = .{ .workspace = @enumFromInt(1) },
    .tab_id = @enumFromInt(1),
};
pub const bootstrap_pane: core.PaneId = @enumFromInt(10);

/// Grid the client starts with, as the terminal harness used.
const host_cols = 80;
const host_rows = 24;
/// Host requests a test can read back, oldest first.
const recorded_capacity = 64;

connection: localsocket.SocketChannel,
peer: localsocket.SocketChannel,
client: *client_module.Client,
inbox: Inbox,
adapter: client_module.HeadlessAdapter,
effects: [recorded_capacity]data.HostEffects.Effect = undefined,
effect_count: usize = 0,
graphics: RetainedGraphics = .{},

/// Example: `var harness: ClientHarness = undefined; try harness.init(); defer harness.deinit();`
pub fn init(self: *ClientHarness) !void {
    try self.initWithOptions(.{ .arguments = &.{}, .cwd = "/", .endpoint = "" });
}

/// Starts the client with explicit options, such as a loaded configuration
/// generation the client adopts.
/// Example: `try harness.initWithOptions(options);`
pub fn initWithOptions(self: *ClientHarness, options: client_module.Options) !void {
    var sockets: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets) != 0) {
        return error.SocketPairFailed;
    }

    self.* = .{
        .connection = .init(.{ .socket = .{ .handle = sockets[0], .address = .{ .ip4 = .loopback(0) } } }),
        .peer = .init(.{ .socket = .{ .handle = sockets[1], .address = .{ .ip4 = .loopback(0) } } }),
        .client = try std.testing.allocator.create(client_module.Client),
        .inbox = .init(std.testing.io, .{}),
        .adapter = undefined,
    };
    errdefer std.testing.allocator.destroy(self.client);

    try self.client.init(.{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .connection = &self.connection,
        .host_size = .{ .cols = host_cols, .rows = host_rows, .cell_width_px = 0, .cell_height_px = 0 },
        .options = options,
    });
    self.adapter = .{ .state = &self.client.presentation };
    self.client.graphics = self.graphics.port();
    self.client.chrome = .{
        .context = self,
        .pointer_fn = noPointer,
        .inspection_scroll_limit_fn = noScrollLimit,
    };
    self.client.host_input_source = .{
        .context = self,
        .route_prompt_bytes_fn = noPromptBytes,
    };
}

pub fn deinit(self: *ClientHarness) void {
    const io = std.testing.io;
    self.inbox.deinit();
    if (self.client.presentation.active) |flight| {
        _ = self.client.presentation.complete(flight.token, .cancelled);
    }

    self.client.deinit();
    std.testing.allocator.destroy(self.client);
    self.peer.deinit(io);
    self.connection.deinit(io);
}

/// Drives the real dispatch until the outbox is drained, so a test
/// observes exactly what the runtime peer would receive.
/// Example: `try harness.settle();`
pub fn settle(self: *ClientHarness) !void {
    while (self.client.model.to_runtime.inFlight() or self.client.model.to_runtime.len != 0) {
        try self.deliverHostEffects();
        switch (try self.inbox.receive()) {
            .client => |message| switch (message) {
                .sent, .sidebar_animation_tick, .notification_tick, .bar_tick, .bar_command, .path_completion => {
                    _ = try self.client.update(message);
                    try self.deliverHostEffects();
                    try self.present();
                },
                else => return error.UnexpectedEvent,
            },
        }
    }

    try data.model_invariants.check(&self.client.model);
}

/// Records the host requests a direct client call left and starts the
/// jobs it queued, as the event loop does after every event.
/// Example: `try harness.deliverHostEffects();`
pub fn deliverHostEffects(self: *ClientHarness) !void {
    const effects = &self.client.model.to_host;
    _ = effects.takePlacementInvalidation();
    effects.resume_input = false;
    effects.rebind_input = false;
    effects.pane_input = null;
    while (effects.pop()) |effect| {
        if (self.effect_count < self.effects.len) {
            self.effects[self.effect_count] = effect;
            self.effect_count += 1;
        }
    }

    try self.startJobs();
    try data.model_invariants.check(&self.client.model);
}

/// The host requests recorded so far.
pub fn recordedEffects(self: *const ClientHarness) []const data.HostEffects.Effect {
    return self.effects[0..self.effect_count];
}

/// Prepares and completes one presentation when the model asks for one,
/// acknowledging the frames it carried.
/// Example: `try harness.present();`
pub fn present(self: *ClientHarness) !void {
    const model = &self.client.model;
    const projection = client_module.capture(model, .{ .geometry = data.workbench.region(model) });
    const token = self.adapter.prepare(projection) catch |err| switch (err) {
        error.PresentationBusy => return,
        else => return err,
    } orelse return;

    const delivery = self.adapter.complete(token, .delivered) orelse return;
    try client_module.presentation_delivery.apply(model, delivery.commit);
    try self.startJobs();
}

/// Presents until the prepared state matches the model, running the timer
/// and write completions that arrive meanwhile.
/// Example: `try harness.settleModelPresentation();`
pub fn settleModelPresentation(self: *ClientHarness) !void {
    try self.present();
    try self.settle();
}

/// Starts what a direct client call queued, then receives the next event.
/// Example: `switch (try harness.receiveClient()) { .sent => |result| ..., else => return error.UnexpectedEvent }`
pub fn receiveClient(self: *ClientHarness) !client_module.Message {
    try self.deliverHostEffects();
    return switch (try self.inbox.receive()) {
        .client => |message| message,
    };
}

/// Receives the next message the client sent to the runtime, first starting
/// the write a direct client call left queued, as the event loop would.
/// Example: `const message = try harness.nextClientMessage(&buffer);`
pub fn nextClientMessage(self: *ClientHarness, buffer: []u8) !core.ClientMessage {
    try self.deliverHostEffects();
    return self.receiveClientMessage(buffer);
}

/// Receives the next message already on the runtime's side of the socket.
/// It touches only the peer, so a concurrent reader may call it while the
/// test thread drives the client with `settle`.
/// Example: `const message = try harness.receiveClientMessage(&buffer);`
pub fn receiveClientMessage(self: *ClientHarness, buffer: []u8) !core.ClientMessage {
    const payload = try self.peer.receive(std.testing.io, buffer);
    return core.decodeClient(payload);
}

/// Delivers one encoded server message through the real entry point.
/// Example: `const status = try harness.receiveServer(encoded);`
pub fn receiveServer(self: *ClientHarness, encoded: []const u8) !?u8 {
    const status = try client_module.runtime_messages.handleServerMessage(self.client, try core.decodeServer(encoded));
    try self.deliverHostEffects();
    return status;
}

pub fn nextAttachmentRequest(self: *ClientHarness, pane_id: core.PaneId, buffer: []u8) !core.RequestId {
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

pub fn discoverAndRequestAttachment(self: *ClientHarness, pane_id: core.PaneId, buffer: []u8) !core.RequestId {
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

/// Answers the initial open request through the real entrypoint, leaving
/// the client with one attached pane and its two snapshot requests (ids
/// 2 and 3) delivered to the peer.
/// Example: `try harness.bootstrap();`
pub fn bootstrap(self: *ClientHarness) !void {
    try self.client.model.request_lifecycle.tracker.add(client_module.initial_request_id, .{ .initial_open = .{} });
    var payload: [128]u8 = undefined;
    const opened = try core.encodePaneOpened(&payload, .{
        .request_id = client_module.initial_request_id,
        .pane_id = bootstrap_pane,
        .location = bootstrap_location,
        .created = true,
    });
    try std.testing.expectEqual(@as(?u8, null), try client_module.runtime_messages.handleServerMessage(self.client, try core.decodeServer(opened)));
    try self.settle();

    var buffer: [256]u8 = undefined;
    const first = try self.nextClientMessage(&buffer);
    try std.testing.expect(first == .request_workspace_snapshot);
    const second = try self.nextClientMessage(&buffer);
    try std.testing.expect(second == .request_tab_snapshot);
    try self.settleModelPresentation();
}

pub fn addTab(self: *ClientHarness, tab_id: core.TabId, pane_id: core.PaneId) !core.TabLocation {
    const location: core.TabLocation = .{
        .workspace = bootstrap_location.workspace,
        .tab_id = tab_id,
    };

    _ = try data.tab_creation.add(&self.client.model, .{
        .location = location,
        .position = @intCast(self.client.model.tabs.count),
        .label = "second",
        .root_pane_id = pane_id,
    }, .{ .cols = host_cols, .rows = host_rows });

    return location;
}

pub fn addInactiveTab(self: *ClientHarness, tab_id: core.TabId, pane_id: core.PaneId) !core.TabLocation {
    const location = try self.addTab(tab_id, pane_id);
    var panes = self.client.model.panes.iterate(tab_id);
    while (panes.next()) |pane| {
        pane.attached = false;
        pane.pending_frame_id = 0;
    }

    try self.graphics.setPaneVisible(pane_id, false);
    try std.testing.expect(data.tab_selection.select(&self.client.model, bootstrap_location.tab_id));
    return location;
}

pub fn allowTabSelection(self: *ClientHarness) !void {
    const continuation = self.client.model.request_lifecycle.tracker.take(@enumFromInt(3)) orelse
        return error.MissingBootstrapTabSnapshot;
    try std.testing.expect(continuation == .tab_snapshot);
}

fn startJobs(self: *ClientHarness) !void {
    const app = self.client;
    try app.flush();
    while (true) {
        if (app.to_workers.pop()) |job| {
            self.inbox.start(.client, .{ client_module.job_runner.run, .{ std.testing.io, job } }) catch |err| {
                try app.failJob(job, err);
                try app.flush();
            };
        } else if (app.to_background.pop()) |job| {
            self.inbox.start(.client, .{ client_module.job_runner.runBackground, .{ std.testing.io, std.testing.allocator, job } }) catch |err| {
                try app.failBackgroundJob(job, err);
                try app.flush();
            };
        } else {
            return;
        }
    }
}

fn noPointer(_: *anyopaque, _: keyinput.Mouse) client_module.ViewInteractionCommand {
    return .{};
}

fn noScrollLimit(_: *anyopaque) ?u32 {
    return null;
}

fn noPromptBytes(_: *anyopaque, _: []const u8) anyerror!void {}
