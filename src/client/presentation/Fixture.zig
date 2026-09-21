const Client = @import("../AttachedClient.zig");
const core = @import("telar-core");
const server_messages = @import("../entrypoints/server_messages.zig");
const pane_inputs = @import("../operations/input/pane_inputs.zig");
const presentation_delivery = @import("../operations/session/presentation_delivery.zig");
const TransportState = @import("../connection/RuntimeTransportState.zig");
const Target = @import("../attachments/AttachmentTarget.zig");
const Credit = @import("../graphics/Credit.zig");
const Region = @import("../workspace/Region.zig");
const pane_graphics = @import("../application/panes/pane_graphics.zig");
const ModelType = @import("../model/Model.zig");
const AdapterType = @import("HeadlessAdapter.zig");
const OutboxType = @import("../connection/Outbox.zig");
const retained_module = @import("../graphics/retained.zig");
const StateType = @import("../workspace/State.zig");
const std = @import("std");
const headless_tests = @import("headless_tests.zig");
const ProjectionType = @import("Projection.zig");
const projection_support = @import("projection_support.zig");
const lifecycle_module = @import("lifecycle.zig");
const RuntimeMessage = @import("../connection/RuntimeMessage.zig");
const GenericInbox = @import("../execution/GenericInbox.zig").Type;
const Message = @import("headless_event.zig").Message;
const PaneIdType = @import("telar-core").PaneId;
const KeyType = @import("../input/Key.zig");
const Fixture = @This();

app: Client,
model: *ModelType,
connection: core.SocketChannel,
peer: core.SocketChannel,
pending: ?[]const u8 = null,
inbox: GenericInbox(Message),
receive_buffer: [64 * 1024]u8 = undefined,
received: RuntimeMessage = undefined,
receive_pending: bool = false,
adapter: AdapterType = .{},
outbox: *OutboxType,
graphics: retained_module.Store,
geometry: StateType = .{},
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
    fixture.app.transport_driver = .{ .context = fixture, .start_read_fn = startRead, .start_send_fn = startSend };
    fixture.app.graphics = .{ .context = fixture, .apply_fn = unsupportedGraphics, .clear_pane_fn = clearPane, .set_pane_visible_fn = setVisible, .pane_visible_fn = visible, .has_pane_graphics_fn = hasGraphics, .ingress_version_fn = ingress, .peek_credit_fn = peekCredit, .consume_credit_fn = consumeCredit };
    fixture.app.attachment_shelf.context = fixture;
    fixture.app.attachment_shelf.sync_target_fn = syncTarget;
    fixture.app.attachment_catalog.context = fixture;
    fixture.app.attachment_catalog.visible_target_fn = noTarget;
    fixture.app.chrome.context = fixture;
    fixture.app.chrome.region_fn = region;
    fixture.app.host_input_source.context = fixture;
    fixture.app.host_input_source.resume_read_fn = resumeRead;
    fixture.app.presentation.note_pane_input_fn = null;
    fixture.geometry.update(.{ .w = 40, .h = 10 });
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
    return projection_support.capture(fixture.model, .{ .geometry = fixture.geometry.current });
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
    fixture.received = try RuntimeMessage.decode(std.testing.io, fixture.receive_buffer[0..bytes.len]);
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
                _ = try server_messages.handleServerMessage(&fixture.app, received.message);
            },
            .key => |value| try fixture.applyKey(value),
            .completed => |value| try fixture.deliver(value.token, value.outcome),
        }
    }
}

fn visible(context: *anyopaque, id: PaneIdType) bool {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    return fixture.graphics.paneVisible(id);
}

fn setVisible(context: *anyopaque, id: PaneIdType, value: bool) !void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    try fixture.graphics.setPaneVisible(id, value);
}

fn syncTarget(context: *anyopaque, _: ?Target) bool {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    fixture.resource_syncs += 1;
    return false;
}

fn noTarget(_: *anyopaque) ?Target {
    return null;
}

fn startRead(_: *anyopaque, _: *TransportState) !void {
    return error.HeadlessReadUnsupported;
}

fn startSend(context: *anyopaque, _: *TransportState, bytes: []const u8) !void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    std.debug.assert(fixture.pending == null);
    fixture.pending = bytes;
}

fn resumeRead(_: *anyopaque) !void {}

fn region(context: *anyopaque) Region {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    return fixture.geometry.current;
}

fn unsupportedGraphics(_: *anyopaque, _: pane_graphics.Command) !void {
    return error.HeadlessGraphicsUnsupported;
}

fn clearPane(context: *anyopaque, id: PaneIdType) void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    fixture.graphics.clearPane(id);
}

fn hasGraphics(context: *anyopaque, id: PaneIdType) bool {
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

pub fn key(fixture: *Fixture, value: KeyType) !void {
    try fixture.inbox.post(.{ .key = value });
    try fixture.drain();
}

fn applyKey(fixture: *Fixture, value: KeyType) !void {
    _ = try pane_inputs.send(&fixture.app, .{ .target = .focused, .source = .host, .payload = .{ .key = value } });
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
