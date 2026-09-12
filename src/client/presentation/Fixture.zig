const ModelType = @import("../model/Model.zig");
const AdapterType = @import("HeadlessAdapter.zig");
const OutboxType = @import("../connection/Outbox.zig");
const retained_module = @import("../graphics/retained.zig");
const StateType = @import("../workspace/State.zig");
const std = @import("std");
const ConfirmWorkspaceHandoffHandlerType = @import("../application/workspaces/ConfirmWorkspaceHandoffHandler.zig");
const headless_tests = @import("headless_tests.zig");
const WorkspaceActivationType = @import("../model/WorkspaceActivation.zig");
const ProjectionType = @import("Projection.zig");
const projection_support = @import("projection_support.zig");
const lifecycle_module = @import("lifecycle.zig");
const DeliverPresentationHandlerType = @import("../application/presentation/DeliverPresentationHandler.zig");
const ServerMessageType = @import("telar-core").ServerMessage;
const runtime_messages_module = @import("../entrypoints/runtime_messages.zig");
const Adapters = @import("Adapters.zig");
const PaneFrameRecoveryType = @import("../model/PaneFrameRecovery.zig");
const PaneFrameCommitType = @import("../model/PaneFrameCommit.zig");
const DeliverPaneFrameHandlerType = @import("../application/panes/DeliverPaneFrameHandler.zig");
const PaneIdType = @import("telar-core").PaneId;
const FrameAckType = @import("telar-core").FrameAck;
const KeyType = @import("../input/Key.zig");
const PaneInputHandlerType = @import("../application/input/PaneInputHandler.zig");
const PaneInputEffectType = @import("../application/input/PaneInputEffect.zig");
const PaneViewportChangeType = @import("../model/PaneViewportChange.zig");
const Fixture = @This();

model: ModelType,
adapter: AdapterType = .{},
outbox: OutboxType = .{},
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
    fixture.* = .{ .model = ModelType.init(allocator, true), .graphics = retained_module.Store.init(allocator) };
    errdefer fixture.model.deinit();
    fixture.geometry.update(.{ .w = 40, .h = 10 });
    try fixture.arrive();
    return fixture;
}

pub fn deinit(fixture: *Fixture) void {
    if (fixture.adapter.state.active) |flight| {
        _ = fixture.adapter.complete(flight.token, .cancelled);
    }

    fixture.graphics.deinit();
    fixture.model.deinit();
    std.testing.allocator.destroy(fixture);
}

pub fn arrive(fixture: *Fixture) !void {
    var handler: ConfirmWorkspaceHandoffHandlerType = .{
        .model = &fixture.model,
        .delivery = .{ .context = fixture, .deliver = activated },
    };
    try handler.execute(.{ .pane_id = headless_tests.pane_id, .location = headless_tests.location, .size = .{ .cols = 4, .rows = 1 } });
}

fn activated(context: *anyopaque, _: WorkspaceActivationType) !void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    fixture.activations += 1;
}

pub fn projection(fixture: *Fixture) ProjectionType {
    return projection_support.capture(&fixture.model, .{ .geometry = fixture.geometry.current });
}

pub fn prepare(fixture: *Fixture) !lifecycle_module.Token {
    return (try fixture.adapter.prepare(fixture.projection())) orelse error.ExpectedPresentation;
}

pub fn complete(fixture: *Fixture, token: lifecycle_module.Token, outcome: lifecycle_module.Outcome) !void {
    const delivery = fixture.adapter.complete(token, outcome) orelse return;
    var handler: DeliverPresentationHandlerType = .{
        .model = &fixture.model,
        .effects = .{ .context = fixture, .flush_graphics_credits = credits, .request_media = media },
    };
    try handler.execute(.{ .commit = delivery.commit, .media_pending = delivery.media_pending });
}

pub fn receive(fixture: *Fixture, message: ServerMessageType) !void {
    _ = try runtime_messages_module.dispatch(fixture, message, Adapters);
}

pub fn recover(context: *anyopaque, recovery: PaneFrameRecoveryType) !void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    try fixture.outbox.push(.{ .request_snapshot = .{ .pane_id = recovery.pane_id, .known_frame_id = recovery.known_frame_id } });
}

pub fn frameResources(context: *anyopaque, commit: PaneFrameCommitType) !void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    var handler: DeliverPaneFrameHandlerType = .{
        .model = &fixture.model,
        .effects = .{ .context = fixture, .pane_graphics_visible = visible, .set_pane_graphics_visible = setVisible, .synchronize_active_resources = synchronize },
    };
    try handler.execute(commit);
}

fn visible(context: *anyopaque, id: PaneIdType) bool {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    return fixture.graphics.paneVisible(id);
}

fn setVisible(context: *anyopaque, id: PaneIdType, value: bool) !void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    try fixture.graphics.setPaneVisible(id, value);
}

fn synchronize(context: *anyopaque) !void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    fixture.resource_syncs += 1;
}

fn credits(context: *anyopaque) !void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    while (fixture.graphics.peekCredit()) |credit| {
        try fixture.outbox.push(.{ .graphics_credit = .{ .pane_id = credit.pane_id, .bytes = credit.bytes } });
        fixture.graphics.consumeCredit(credit);
    }
}

/// Queues an applied-cell ACK independently of presentation. Example: `try Fixture.acknowledge(fixture, ack);`.
pub fn acknowledge(context: *anyopaque, ack: FrameAckType) !void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    try fixture.outbox.push(.{ .frame_ack = ack });
}

fn media(context: *anyopaque) !void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    fixture.media_requests += 1;
}

pub fn key(fixture: *Fixture, value: KeyType) !void {
    var handler: PaneInputHandlerType = .{
        .model = &fixture.model,
        .effects = .{ .context = fixture, .send = sendInput, .viewport = .{ .context = fixture, .sync = viewport } },
    };
    _ = try handler.execute(.{ .target = .focused, .source = .host, .payload = .{ .key = value } });
}

fn sendInput(context: *anyopaque, value: PaneInputEffectType) !void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    try fixture.outbox.pushInput(value.pane_id, value.bytes);
}

fn viewport(context: *anyopaque, value: PaneViewportChangeType) !void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    try fixture.outbox.push(.{ .set_pane_viewport = .{ .pane_id = value.pane_id, .offset = value.offset } });
}

pub fn expectAck(fixture: *Fixture, frame_id: u64) !void {
    try std.testing.expectEqual(frame_id, fixture.outbox.peek().?.frame_ack.frame_id);
    try fixture.sendOne();
}

pub fn sendOne(fixture: *Fixture) !void {
    var wire: [1024]u8 = undefined;
    try std.testing.expect((try fixture.outbox.beginSend(&wire)) != null);
    try fixture.outbox.finishSend({});
}
