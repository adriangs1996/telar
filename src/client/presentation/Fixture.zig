const headless_event = @import("headless_event.zig");
const model_data = @import("model");
const Client = @import("../AttachedClient.zig");
const core = @import("telar-core");
const presentation_delivery = @import("../connection/presentation_delivery.zig");
const TransportState = @import("../connection/RuntimeTransportState.zig");
const Credit = @import("../graphics/Credit.zig");
const HeadlessAdapter = @import("HeadlessAdapter.zig");
const retained_module = @import("../graphics/retained.zig");
const std = @import("std");
const headless_tests = @import("headless_tests.zig");
const Projection = @import("Projection.zig");
const projection_support = @import("projection_support.zig");
const lifecycle_module = @import("lifecycle.zig");
const GenericInbox = @import("../execution/GenericInbox.zig").Type;
const Fixture = @This();

app: Client,
model: *model_data.ClientModel,
connection: core.SocketChannel,
peer: core.SocketChannel,
pending: ?[]const u8 = null,
inbox: GenericInbox(headless_event.Message),
receive_buffer: [64 * 1024]u8 = undefined,
received: model_data.RuntimeMessage = undefined,
receive_pending: bool = false,
adapter: HeadlessAdapter = undefined,
outbox: *model_data.Outbox,
graphics: retained_module.Store,
activations: usize = 0,
media_requests: usize = 0,

pub fn init() !*Fixture {
    return initWithAllocator(std.testing.allocator);
}

pub fn initWithAllocator(allocator: std.mem.Allocator) !*Fixture {
    const fixture = try std.testing.allocator.create(Fixture);
    errdefer std.testing.allocator.destroy(fixture);
    fixture.* = .{ .app = undefined, .model = undefined, .outbox = undefined, .connection = undefined, .peer = undefined, .graphics = retained_module.Store.init(allocator), .inbox = .init(std.testing.io, .{}) };
    errdefer fixture.graphics.deinit();
    var sockets: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets) != 0) {
        return error.SocketPairFailed;
    }
    fixture.connection = .init(.{ .socket = .{ .handle = sockets[0], .address = .{ .ip4 = .loopback(0) } } });
    fixture.peer = .init(.{ .socket = .{ .handle = sockets[1], .address = .{ .ip4 = .loopback(0) } } });
    errdefer fixture.connection.deinit(std.testing.io);
    errdefer fixture.peer.deinit(std.testing.io);
    try fixture.app.init(.{ .gpa = allocator, .io = std.testing.io, .connection = &fixture.connection, .host_size = .{ .cols = 40, .rows = 10, .cell_width_px = 0, .cell_height_px = 0 }, .options = .{ .arguments = &.{}, .cwd = "/", .endpoint = "" } });
    errdefer fixture.app.deinit();
    fixture.model = &fixture.app.model;
    fixture.outbox = &fixture.app.model.to_runtime;
    // Only host boundaries are substituted; server dispatch, input and delivery
    // execute the production operations. Unused host capabilities stay unbound.
    fixture.app.graphics = .{ .context = fixture, .apply_fn = unsupportedGraphics, .clear_pane_fn = clearPane, .set_pane_visible_fn = setVisible, .pane_visible_fn = visible, .has_pane_graphics_fn = hasGraphics, .ingress_version_fn = ingress, .peek_credit_fn = peekCredit, .consume_credit_fn = consumeCredit };
    fixture.adapter = .{ .state = &fixture.app.presentation };
    fixture.app.model.host.animation_frame_ns = core.pace.default_interval;
    try fixture.arrive();
    return fixture;
}

pub fn deinit(self: *Fixture) void {
    self.inbox.deinit();
    if (self.adapter.state.active) |flight| {
        _ = self.adapter.complete(flight.token, .cancelled);
    }

    self.graphics.deinit();
    self.app.deinit();
    self.connection.deinit(std.testing.io);
    self.peer.deinit(std.testing.io);
    std.testing.allocator.destroy(self);
}

pub fn arrive(self: *Fixture) !void {
    _ = try self.model.arriveWorkspace(.{ .pane_id = headless_tests.pane_id, .location = headless_tests.location, .size = .{ .cols = 4, .rows = 1 } });
    self.activations += 1;
}

pub fn projection(self: *Fixture) Projection {
    return projection_support.capture(self.model, .{ .geometry = model_data.workbench.region(self.model) });
}

pub fn prepare(self: *Fixture) !lifecycle_module.Token {
    return (try self.adapter.prepare(self.projection())) orelse error.ExpectedPresentation;
}

pub fn complete(self: *Fixture, token: lifecycle_module.Token, outcome: lifecycle_module.Outcome) !void {
    try self.inbox.post(.{ .completed = .{ .token = token, .outcome = outcome } });
    try self.drain();
}

fn deliver(self: *Fixture, token: lifecycle_module.Token, outcome: lifecycle_module.Outcome) !void {
    const delivery = self.adapter.complete(token, outcome) orelse return;
    try presentation_delivery.apply(&self.app, delivery.commit);
    if (delivery.media_pending) {
        self.media_requests += 1;
    }
}

pub fn receive(self: *Fixture, bytes: []const u8) !void {
    try self.postFrame(bytes);
    try self.drain();
}

/// Owns the wire bytes through delayed dispatch, as a transport reservation does.
/// Example: `try fixture.postFrame(encoded); @memset(encoded, 0); try fixture.drain();`
pub fn postFrame(self: *Fixture, bytes: []const u8) !void {
    if (self.receive_pending) {
        return error.ReceiveBusy;
    }

    if (bytes.len > self.receive_buffer.len) {
        return error.HeadlessReceiveTooLarge;
    }

    const ticket = try self.inbox.reserve();
    errdefer self.inbox.release(ticket);
    @memcpy(self.receive_buffer[0..bytes.len], bytes);
    self.received = try model_data.RuntimeMessage.decode(std.testing.io, self.receive_buffer[0..bytes.len]);
    self.receive_pending = true;
    std.debug.assert(self.inbox.publish(ticket, .{ .server = &self.received }));
}

/// The same finite consumer boundary used by the terminal and native hosts.
/// Example: `try fixture.drain();`
pub fn drain(self: *Fixture) !void {
    var turn = try self.inbox.begin();
    defer self.inbox.end();
    while (try self.inbox.next(&turn)) |message| {
        switch (message) {
            .server => |received| {
                defer self.receive_pending = false;
                _ = try self.app.handleServerMessage(received.message);
            },
            .key => |value| try self.applyKey(value),
            .completed => |value| try self.deliver(value.token, value.outcome),
        }

        try self.startJobs();
    }
}

fn visible(context: *anyopaque, id: core.PaneId) bool {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    return fixture.graphics.paneVisible(id);
}

fn setVisible(context: *anyopaque, id: core.PaneId, value: bool) !void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    try fixture.graphics.setPaneVisible(id, value);
}

/// Holds the runtime write as the transport would; headless hosts run no
/// other job.
fn startJobs(self: *Fixture) !void {
    try self.app.flush();
    while (self.app.to_workers.pop()) |job| {
        switch (job) {
            .runtime_send => |send| {
                std.debug.assert(self.pending == null);
                self.pending = send.bytes;
            },
            .runtime_read => return error.HeadlessReadUnsupported,
            else => return error.HeadlessJobUnsupported,
        }
    }
}

fn unsupportedGraphics(_: *anyopaque, _: model_data.PaneGraphicsCommand) !void {
    return error.HeadlessGraphicsUnsupported;
}

fn clearPane(context: *anyopaque, id: core.PaneId) void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    fixture.graphics.clearPane(id);
}

fn hasGraphics(context: *anyopaque, id: core.PaneId) bool {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    return fixture.graphics.hasPaneGraphics(id);
}

fn ingress(context: *anyopaque) u64 {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    return fixture.graphics.ingressVersion();
}

fn peekCredit(context: *anyopaque) ?Credit {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    return fixture.graphics.peekCredit();
}

fn consumeCredit(context: *anyopaque, credit: Credit) void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    fixture.graphics.consumeCredit(credit);
}

pub fn key(self: *Fixture, value: model_data.Key) !void {
    try self.inbox.post(.{ .key = value });
    try self.drain();
}

fn applyKey(self: *Fixture, value: model_data.Key) !void {
    _ = try self.app.sendPaneInput(
        .{
            .target = .focused,
            .source = .host,
            .payload = .{
                .key = value,
            },
        },
    );
}

pub fn expectAck(self: *Fixture, frame_id: u64) !void {
    try std.testing.expectEqual(frame_id, self.outbox.peek().?.frame_ack.frame_id);
    try self.sendOne();
}

pub fn sendOne(self: *Fixture) !void {
    try std.testing.expect(self.pending != null);
    self.pending = null;
    try self.app.completeRuntimeSend({});
    try self.startJobs();
}
