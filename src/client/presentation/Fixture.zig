const headless_event = @import("headless_event.zig");
const model_data = @import("model");
const Client = @import("../AttachedClient.zig");
const core = @import("telar-core");
const presentation_delivery = @import("../operations/session/presentation_delivery.zig");
const TransportState = @import("../connection/RuntimeTransportState.zig");
const Credit = @import("../graphics/Credit.zig");
const AdapterType = @import("HeadlessAdapter.zig");
const retained_module = @import("../graphics/retained.zig");
const std = @import("std");
const Job = @import("../execution/Job.zig").Job;
const headless_tests = @import("headless_tests.zig");
const ProjectionType = @import("Projection.zig");
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
adapter: AdapterType = undefined,
outbox: *model_data.Outbox,
graphics: retained_module.Store,
activations: usize = 0,
resource_syncs: usize = 0,
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
    fixture.outbox = &fixture.app.runtime_transport.outbox;
    // Only host boundaries are substituted; server dispatch, input and delivery
    // execute the production operations. Unused host capabilities stay unbound.
    fixture.app.workers = .{ .context = fixture, .start_fn = startJob };
    fixture.app.graphics = .{ .context = fixture, .apply_fn = unsupportedGraphics, .clear_pane_fn = clearPane, .set_pane_visible_fn = setVisible, .pane_visible_fn = visible, .has_pane_graphics_fn = hasGraphics, .ingress_version_fn = ingress, .peek_credit_fn = peekCredit, .consume_credit_fn = consumeCredit };
    fixture.app.attachment_shelf.context = fixture;
    fixture.app.attachment_shelf.sync_target_fn = syncTarget;
    fixture.app.attachment_catalog.context = fixture;
    fixture.app.attachment_catalog.visible_target_fn = noTarget;
    fixture.adapter = .{ .state = &fixture.app.presentation };
    fixture.app.model.host.animation_frame_ns = core.pace.default_interval;
    try fixture.arrive();
    return fixture;
}

pub fn deinit(fixture: *Fixture) void {
    fixture.inbox.deinit();
    if (fixture.adapter.state.active) |flight| {
        _ = fixture.adapter.complete(flight.token, .cancelled);
    }

    fixture.graphics.deinit();
    fixture.app.deinit();
    fixture.connection.deinit(std.testing.io);
    fixture.peer.deinit(std.testing.io);
    std.testing.allocator.destroy(fixture);
}

pub fn arrive(fixture: *Fixture) !void {
    _ = try fixture.model.arriveWorkspace(.{ .pane_id = headless_tests.pane_id, .location = headless_tests.location, .size = .{ .cols = 4, .rows = 1 } });
    fixture.activations += 1;
}

pub fn projection(fixture: *Fixture) ProjectionType {
    return projection_support.capture(fixture.model, .{ .geometry = model_data.workbench.region(fixture.model) });
}

pub fn prepare(fixture: *Fixture) !lifecycle_module.Token {
    return (try fixture.adapter.prepare(fixture.projection())) orelse error.ExpectedPresentation;
}

pub fn complete(fixture: *Fixture, token: lifecycle_module.Token, outcome: lifecycle_module.Outcome) !void {
    try fixture.inbox.post(.{ .completed = .{ .token = token, .outcome = outcome } });
    try fixture.drain();
}

fn deliver(fixture: *Fixture, token: lifecycle_module.Token, outcome: lifecycle_module.Outcome) !void {
    const delivery = fixture.adapter.complete(token, outcome) orelse return;
    try presentation_delivery.apply(&fixture.app, delivery.commit);
    if (delivery.media_pending) {
        fixture.media_requests += 1;
    }
}

pub fn receive(fixture: *Fixture, bytes: []const u8) !void {
    try fixture.postFrame(bytes);
    try fixture.drain();
}

/// Owns the wire bytes through delayed dispatch, as a transport reservation does.
/// Example: `try fixture.postFrame(encoded); @memset(encoded, 0); try fixture.drain();`
pub fn postFrame(fixture: *Fixture, bytes: []const u8) !void {
    if (fixture.receive_pending) {
        return error.ReceiveBusy;
    }

    if (bytes.len > fixture.receive_buffer.len) {
        return error.HeadlessReceiveTooLarge;
    }

    const ticket = try fixture.inbox.reserve();
    errdefer fixture.inbox.release(ticket);
    @memcpy(fixture.receive_buffer[0..bytes.len], bytes);
    fixture.received = try model_data.RuntimeMessage.decode(std.testing.io, fixture.receive_buffer[0..bytes.len]);
    fixture.receive_pending = true;
    std.debug.assert(fixture.inbox.publish(ticket, .{ .server = &fixture.received }));
}

/// The same finite consumer boundary used by the terminal and native hosts.
/// Example: `try fixture.drain();`
pub fn drain(fixture: *Fixture) !void {
    var turn = try fixture.inbox.begin();
    defer fixture.inbox.end();
    while (try fixture.inbox.next(&turn)) |message| {
        switch (message) {
            .server => |received| {
                defer fixture.receive_pending = false;
                _ = try fixture.app.handleServerMessage(received.message);
            },
            .key => |value| try fixture.applyKey(value),
            .completed => |value| try fixture.deliver(value.token, value.outcome),
        }
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

fn syncTarget(context: *anyopaque, _: ?model_data.AttachmentTarget) bool {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    fixture.resource_syncs += 1;
    return false;
}

fn noTarget(_: *anyopaque) ?model_data.AttachmentTarget {
    return null;
}

fn startJob(context: *anyopaque, job: Job) !void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    switch (job) {
        .runtime_send => |send| {
            std.debug.assert(fixture.pending == null);
            fixture.pending = send.bytes;
        },
        .runtime_read => return error.HeadlessReadUnsupported,
        else => return error.HeadlessJobUnsupported,
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

pub fn key(fixture: *Fixture, value: model_data.Key) !void {
    try fixture.inbox.post(.{ .key = value });
    try fixture.drain();
}

fn applyKey(fixture: *Fixture, value: model_data.Key) !void {
    _ = try fixture.app.sendPaneInput(
        .{
            .target = .focused,
            .source = .host,
            .payload = .{
                .key = value,
            },
        },
    );
}

pub fn expectAck(fixture: *Fixture, frame_id: u64) !void {
    try std.testing.expectEqual(frame_id, fixture.outbox.peek().?.frame_ack.frame_id);
    try fixture.sendOne();
}

pub fn sendOne(fixture: *Fixture) !void {
    try std.testing.expect(fixture.pending != null);
    fixture.pending = null;
    try fixture.app.completeRuntimeSend({});
}
