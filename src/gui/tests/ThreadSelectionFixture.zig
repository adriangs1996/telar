//! Headless native reader fixture; no window or desktop input is created.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Session = @import("Session.zig");
const Target = @import("../widgets/interaction/Target.zig");
const Fixture = @This();

session: *Session,
pub const pane_id = Session.pane_id;
pub const location = Session.location;

pub fn init() !Fixture {
    const session = try Session.init();
    errdefer session.deinit();
    try session.bootstrap();
    const size = try session.gui.measure(&session.renderer, .{ .width = 1000, .height = 800, .scale = 1 });
    try session.gui.resize(size, session.renderer.theme);
    session.gui.input.setGeometry(session.renderer.origin, size);
    try session.settle();
    try std.testing.expect(session.gui.app.model.identifyPane(.{ .request_id = @enumFromInt(1), .pane_id = pane_id, .location = location, .created = false, .kind = .agent, .pane_generation = 7 }));
    var fixture: Fixture = .{ .session = session };
    try fixture.messages(&.{ "User **literal** request.", "First **bold** answer and [`input`](https://example.test/hidden).\n```zig\nconst value = 42;\n```", "Second answer with selectable words." });
    try fixture.publish();
    return fixture;
}

pub fn deinit(fixture: *Fixture) void {
    fixture.session.deinit();
}

pub fn publish(fixture: *Fixture) !void {
    const token = try fixture.session.gui.prepare(&fixture.session.renderer);
    try fixture.session.gui.complete(token, true);
    try fixture.session.settle();
}

pub fn send(fixture: *Fixture, event: @import("../input/event.zig").Event) !void {
    try fixture.session.gui.input.acceptEvent(event);
    try fixture.session.gui.input.drain(&fixture.session.gui.app);
}

pub fn messages(fixture: *Fixture, texts: []const []const u8) !void {
    const snapshot = try std.testing.allocator.create(core.AgentThreadSnapshot);
    defer std.testing.allocator.destroy(snapshot);
    const pane = fixture.session.gui.app.model.agentPane(pane_id).?;
    snapshot.* = .{ .pane_id = pane_id, .pane_generation = 7, .revision = if (pane.agent_thread) |current| current.revision + 1 else 1, .status = .ready };
    @memcpy(snapshot.metadata_storage[0..6], "Turn-1");
    snapshot.metadata_len = 6;
    for (texts, 0..) |text, index| {
        var storage: [32]u8 = undefined;
        const source = try std.fmt.bufPrint(&storage, "message-{d}", .{index});
        snapshot.item_storage[index] = .{ .role = if (index == 0) .user else .assistant, .identity = index + 1, .status = .completed, .complete = true, .text_offset = snapshot.text_len, .text_len = @intCast(text.len), .source_offset = snapshot.metadata_len, .source_len = @intCast(source.len), .source_turn_len = 6 };
        @memcpy(snapshot.text_storage[snapshot.text_len..][0..text.len], text);
        @memcpy(snapshot.metadata_storage[snapshot.metadata_len..][0..source.len], source);
        snapshot.text_len += @intCast(text.len);
        snapshot.metadata_len += @intCast(source.len);
    }
    snapshot.item_count = @intCast(texts.len);
    var bytes: [96 * 1024]u8 = undefined;
    _ = try fixture.session.gui.app.model.applyAgentThread((try core.decodeServer(try core.encodeAgentThreadSnapshot(&bytes, snapshot))).agent_thread_snapshot);
}

pub fn target(fixture: *const Fixture, field: enum { transcript, composer }) !Target {
    const registry = fixture.session.gui.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |value| {
        if ((field == .transcript and value.action == .transcript and value.action.transcript == pane_id) or (field == .composer and value.action == .composer and value.action.composer == pane_id)) {
            return value;
        }
    }
    return error.MissingSelectionTarget;
}

pub fn point(fixture: *const Fixture, identity: u64, needle: []const u8) ![2]f64 {
    const pane = fixture.session.gui.app.model.agentPane(pane_id).?;
    const snapshot = pane.threadItemSource(identity) orelse return error.MissingSource;
    const item = snapshot.findItem(identity) orelse return error.MissingSource;
    const offset = item.text_offset + (std.mem.indexOf(u8, item.text(snapshot), needle) orelse return error.MissingText);
    const geometry = fixture.session.gui.widgets.thread_text.?.maps.presented();
    for (geometry.fragments[0..geometry.fragment_count]) |fragment| {
        if (geometry.rows[fragment.row].owner.item_identity != identity or fragment.section != .body) {
            continue;
        }
        for (geometry.carets[fragment.caret_start..][0..fragment.caret_count]) |caret| {
            if (fragment.offset + caret.offset == offset) {
                return .{ fragment.bounds.x + caret.x, fragment.bounds.y + fragment.bounds.height / 2 };
            }
        }
    }
    return error.TextNotVisible;
}

pub fn drag(fixture: *Fixture, points: [2][2]f64) !void {
    try fixture.send(.{ .pointer = .{ .kind = .press, .x = points[0][0], .y = points[0][1] } });
    try fixture.send(.{ .pointer = .{ .kind = .drag, .x = points[1][0], .y = points[1][1] } });
    try fixture.send(.{ .pointer = .{ .kind = .release, .x = points[1][0], .y = points[1][1] } });
}

pub fn clipboard(fixture: *Fixture) !@import("../native/native.zig").HostRequest {
    var request: @import("../native/native.zig").HostRequest = .{};
    if (!fixture.session.gui.host.next(&request)) {
        return error.MissingClipboardWrite;
    }
    return request;
}

pub fn ack(fixture: *Fixture, request: @import("../native/native.zig").HostRequest, status: @import("../input/ClipboardResult.zig").Status) !void {
    try fixture.send(.{ .clipboard = .{ .operation = .write, .request_id = request.request_id, .target_id = request.target_id, .generation = request.generation, .status = status } });
}
