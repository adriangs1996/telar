const Fixture = @This();
const client = @import("../root.zig");
const presentation = @import("root.zig");
const source_namespace = @import("headless_tests.zig");
const std = @import("std");
const Adapters = @import("Adapters.zig");
model: client.model.Model,
adapter: presentation.headless.Adapter = .{},
outbox: client.connection.outbox.Outbox = .{},
graphics: source_namespace.retained.Store,
geometry: client.workspace.geometry.State = .{},
activations: usize = 0,
resource_syncs: usize = 0,
media_requests: usize = 0,

pub fn init() !*Fixture {
    return initWithAllocator(source_namespace.gpa);
}

pub fn initWithAllocator(allocator: std.mem.Allocator) !*Fixture {
    const fixture = try source_namespace.gpa.create(Fixture);
    errdefer source_namespace.gpa.destroy(fixture);
    fixture.* = .{ .model = client.model.Model.init(allocator, true), .graphics = source_namespace.retained.Store.init(allocator) };
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
    source_namespace.gpa.destroy(fixture);
}

pub fn arrive(fixture: *Fixture) !void {
    var handler: source_namespace.app.workspaces.workspace_handoff.ConfirmWorkspaceHandoffHandler = .{
        .model = &fixture.model,
        .delivery = .{ .context = fixture, .deliver = activated },
    };
    try handler.execute(.{ .pane_id = source_namespace.pane_id, .location = source_namespace.location, .size = .{ .cols = 4, .rows = 1 } });
}

fn activated(context: *anyopaque, _: client.model.WorkspaceActivation) !void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    fixture.activations += 1;
}

pub fn projection(fixture: *Fixture) presentation.Projection {
    return presentation.capture(&fixture.model, .{ .geometry = fixture.geometry.current });
}

pub fn prepare(fixture: *Fixture) !presentation.lifecycle.Token {
    return (try fixture.adapter.prepare(fixture.projection())) orelse error.ExpectedPresentation;
}

pub fn complete(fixture: *Fixture, token: presentation.lifecycle.Token, outcome: presentation.lifecycle.Outcome) !void {
    const delivery = fixture.adapter.complete(token, outcome) orelse return;
    var handler: source_namespace.app.presentation.presentation_delivery.DeliverPresentationHandler = .{
        .model = &fixture.model,
        .effects = .{ .context = fixture, .flush_graphics_credits = credits, .acknowledge_frame = acknowledge, .request_media = media },
    };
    try handler.execute(.{ .commit = delivery.commit, .media_pending = delivery.media_pending });
}

pub fn receive(fixture: *Fixture, message: source_namespace.schema.ServerMessage) !void {
    _ = try client.entrypoints.runtime_messages.dispatch(fixture, message, Adapters);
}

pub fn recover(context: *anyopaque, recovery: client.model.PaneFrameRecovery) !void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    try fixture.outbox.push(.{ .request_snapshot = .{ .pane_id = recovery.pane_id, .known_frame_id = recovery.known_frame_id } });
}

pub fn frameResources(context: *anyopaque, commit: client.model.PaneFrameCommit) !void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    var handler: source_namespace.app.panes.pane_frame_delivery.DeliverPaneFrameHandler = .{
        .model = &fixture.model,
        .effects = .{ .context = fixture, .pane_graphics_visible = visible, .set_pane_graphics_visible = setVisible, .synchronize_active_resources = synchronize },
    };
    try handler.execute(commit);
}

fn visible(context: *anyopaque, id: source_namespace.schema.PaneId) bool {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    return fixture.graphics.paneVisible(id);
}

fn setVisible(context: *anyopaque, id: source_namespace.schema.PaneId, value: bool) !void {
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

fn acknowledge(context: *anyopaque, ack: source_namespace.schema.FrameAck) !void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    try fixture.outbox.push(.{ .frame_ack = ack });
}

fn media(context: *anyopaque) !void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    fixture.media_requests += 1;
}

pub fn key(fixture: *Fixture, value: client.input.keybind.Key) !void {
    var handler: source_namespace.app.input.pane_input.PaneInputHandler = .{
        .model = &fixture.model,
        .effects = .{ .context = fixture, .send = sendInput, .viewport = .{ .context = fixture, .sync = viewport } },
    };
    _ = try handler.execute(.{ .target = .focused, .source = .host, .payload = .{ .key = value } });
}

fn sendInput(context: *anyopaque, value: source_namespace.app.input.pane_input.PaneInputEffect) !void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    try fixture.outbox.pushInput(value.pane_id, value.bytes);
}

fn viewport(context: *anyopaque, value: client.model.PaneViewportChange) !void {
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
