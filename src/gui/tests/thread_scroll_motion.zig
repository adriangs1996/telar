const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Session = @import("Session.zig");
const Target = @import("../widgets/interaction/Target.zig");
const Entry = @import("../widgets/interaction/ThreadScrollMotion.zig");
const Event = @import("../input/ScrollEvent.zig");
const scroll = @import("../widgets/interaction/thread_scroll.zig");
const second_pane_id: core.PaneId = @enumFromInt(20);

fn fixture() !*Session {
    const session = try Session.init();
    errdefer session.deinit();
    try session.bootstrap();
    const size = try session.gui.measure(&session.renderer, .{ .width = 800, .height = 600, .scale = 1 });
    try session.gui.resize(size, session.renderer.theme);
    session.gui.input.setGeometry(session.renderer.origin, size);
    try std.testing.expect(session.gui.app.model.identifyPane(.{ .request_id = @enumFromInt(1), .pane_id = Session.pane_id, .location = Session.location, .created = false, .kind = .agent, .pane_generation = 77 }));
    const text = "Earlier output\n" ** 60 ++ "[scroll anchor](https://example.test/anchor)";
    var snapshot: core.AgentThreadSnapshot = .{ .pane_id = Session.pane_id, .pane_generation = 77, .revision = 1, .status = .ready, .item_count = 1, .text_len = text.len };
    snapshot.item_storage[0] = .{ .identity = 42, .role = .assistant, .status = .completed, .text_len = text.len, .complete = true };
    @memcpy(snapshot.text_storage[0..text.len], text);
    var wire: [65536]u8 = undefined;
    const encoded = try core.encodeAgentThreadSnapshot(&wire, &snapshot);
    _ = try client.server_messages.handleServerMessage(&session.gui.app, try core.decodeServer(encoded));
    try publish(session);
    return session;
}

fn publish(session: *Session) !void {
    const token = try session.gui.prepare(&session.renderer);
    try session.gui.complete(token, true);
    try session.settle();
}

fn transcript(session: *Session) !Target {
    return transcriptFor(session, Session.pane_id);
}

fn transcriptFor(session: *Session, pane_id: core.PaneId) !Target {
    const registry = session.gui.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        if (target.action == .transcript and target.action.transcript == pane_id) {
            return target;
        }
    }

    return error.MissingTranscript;
}

fn link(session: *Session) !Target {
    const registry = session.gui.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        if (target.action == .message_link) {
            return target;
        }
    }

    return error.MissingLink;
}

fn entry(session: *Session) !*Entry {
    const pane = session.gui.app.model.agentPane(Session.pane_id).?;
    return session.gui.widgets.thread_scroll.find(.{ .pane_id = pane.id, .pane_generation = pane.attachment_generation }) orelse error.MissingMotion;
}

fn send(session: *Session, event: Event) !void {
    try sendAt(session, try transcript(session), event);
}

fn sendAt(session: *Session, target: Target, event: Event) !void {
    var located = event;
    located.x = target.bounds.x + 2;
    located.y = target.bounds.y + 2;
    try session.gui.input.acceptEvent(.{ .scroll = located });
    try session.gui.input.drain(&session.gui.app);
}

fn addAgentPane(session: *Session) !void {
    const model = session.gui.app.model.activeTabModel().?;
    try model.split(.{ .existing_pane = Session.pane_id, .new_pane = second_pane_id, .location = Session.location, .axis = .horizontal, .area = session.gui.region.area });
    try std.testing.expect(session.gui.app.model.identifyPane(.{ .request_id = @enumFromInt(2), .pane_id = second_pane_id, .location = Session.location, .created = false, .kind = .agent, .pane_generation = 78 }));
    var snapshot = model.findConst(Session.pane_id).?.agent_thread.?.*;
    snapshot.pane_id = second_pane_id;
    snapshot.pane_generation = 78;
    var wire: [65536]u8 = undefined;
    const encoded = try core.encodeAgentThreadSnapshot(&wire, &snapshot);
    _ = try client.server_messages.handleServerMessage(&session.gui.app, try core.decodeServer(encoded));
    try publish(session);
}

fn pinClock(session: *Session) !void {
    const motion = &(try entry(session)).motion;
    motion.hold(motion.spring.position, motion.timestamp_ns + 60 * std.time.ns_per_s);
}

fn advance(session: *Session, elapsed_ns: u64) !void {
    try scroll.advance(session.gui, (try entry(session)).motion.timestamp_ns + elapsed_ns);
}

test "wheel motion delivers intermediate positions and matching link hit geometry" {
    const session = try fixture();
    defer session.deinit();
    const before = try link(session);
    const pane = session.gui.app.model.agentPane(Session.pane_id).?;
    try send(session, .{ .delta_y = -2 });
    try pinClock(session);
    try std.testing.expectEqual(@as(f64, 0), pane.transcript_scroll);
    try std.testing.expectEqual(@as(f64, 2), (try entry(session)).motion.spring.target / (try entry(session)).step);

    var previous: f64 = 0;
    for (0..3) |_| {
        try advance(session, 16 * std.time.ns_per_ms);
        try publish(session);
        try std.testing.expect(pane.transcript_scroll > previous and pane.transcript_scroll < 2);
        const moved = try link(session);
        try std.testing.expectApproxEqAbs(@as(f64, before.bounds.y) + pane.transcript_scroll * (try entry(session)).step, moved.bounds.y, 0.002);
        const hit = session.gui.widgets.dispatcher.maps.presented().at(.{ moved.bounds.x + 1, moved.bounds.y + 1 }).?;
        try std.testing.expect(hit.id.eql(moved.id));
        try std.testing.expect(session.gui.chrome.animation.deadline_ns != null);
        previous = pane.transcript_scroll;
    }

    try advance(session, 2 * std.time.ns_per_s);
    try publish(session);
    try std.testing.expectEqual(@as(f64, 2), pane.transcript_scroll);
    try std.testing.expect(!(try entry(session)).motion.active());
    var clock: @import("../animation/FrameClock.zig") = .{};
    clock.begin((try entry(session)).motion.timestamp_ns);
    session.gui.widgets.thread_scroll.schedule(try transcript(session), &clock);
    try std.testing.expect(clock.deadline_ns == null);
}

test "successive wheel impulses retain current velocity and reverse without jumping" {
    const session = try fixture();
    defer session.deinit();
    try send(session, .{ .delta_y = -2 });
    try pinClock(session);
    try advance(session, 32 * std.time.ns_per_ms);
    try publish(session);
    const before = (try entry(session)).motion.spring;
    try send(session, .{ .delta_y = -2 });
    const repeated = (try entry(session)).motion.spring;
    try std.testing.expectEqual(before.position, repeated.position);
    try std.testing.expectEqual(before.velocity, repeated.velocity);
    try std.testing.expectEqual(before.target * 2, repeated.target);

    try send(session, .{ .delta_y = 6 });
    const reversed = (try entry(session)).motion.spring;
    try std.testing.expectEqual(before.position, reversed.position);
    try std.testing.expectEqual(before.velocity, reversed.velocity);
    try advance(session, 32 * std.time.ns_per_ms);
    try std.testing.expect((try entry(session)).motion.spring.velocity < before.velocity);
    try advance(session, 2 * std.time.ns_per_s);
    try publish(session);
    try std.testing.expectEqual(@as(f64, 0), session.gui.app.model.agentPane(Session.pane_id).?.transcript_scroll);
    try std.testing.expect(!(try entry(session)).motion.active());
}

test "native trackpad deltas and system momentum remain direct without a second tail" {
    const session = try fixture();
    defer session.deinit();
    try send(session, .{ .precise = true, .phase = .begin, .delta_y = -10 });
    try pinClock(session);
    try send(session, .{ .precise = true, .phase = .update, .delta_y = -0.25 });
    try send(session, .{ .precise = true, .phase = .end });
    try send(session, .{ .precise = true, .momentum = .begin, .delta_y = -2 });
    try send(session, .{ .precise = true, .momentum = .update, .delta_y = -0.5 });
    try send(session, .{ .precise = true, .momentum = .end });
    const value = try entry(session);
    try std.testing.expectEqual(@as(f64, 12.75), value.motion.spring.position);
    try std.testing.expect(!value.motion.active());
    try advance(session, 10 * std.time.ns_per_s);
    try publish(session);
    try std.testing.expectApproxEqAbs(@as(f64, 12.75) / value.step, session.gui.app.model.agentPane(Session.pane_id).?.transcript_scroll, 1e-10);
}

test "Wayland finger release moves after end and focus loss cancels its inertia" {
    const session = try fixture();
    defer session.deinit();
    try send(session, .{ .precise = true, .kinetic = true, .phase = .begin, .delta_y = -2, .time_ms = 100 });
    try send(session, .{ .precise = true, .kinetic = true, .phase = .update, .delta_y = -10, .time_ms = 116 });
    try std.testing.expectEqual(@as(f64, 12), (try entry(session)).motion.spring.position);
    try send(session, .{ .precise = true, .kinetic = true, .phase = .end, .time_ms = 116 });
    try pinClock(session);
    try std.testing.expect((try entry(session)).motion.active());
    const velocity = (try entry(session)).motion.spring.velocity;
    try advance(session, 16 * std.time.ns_per_ms);
    try publish(session);
    try std.testing.expect((try entry(session)).motion.spring.position > 12);
    try std.testing.expect((try entry(session)).motion.spring.velocity < velocity);
    const pane = session.gui.app.model.agentPane(Session.pane_id).?;
    const stopped = pane.transcript_scroll;
    try session.gui.focus(false);
    try std.testing.expectEqual(@as(usize, 0), session.gui.widgets.thread_scroll.len);
    try scroll.advance(session.gui, std.math.maxInt(u64));
    try std.testing.expectEqual(stopped, pane.transcript_scroll);
}

test "cancelled gestures and text selection stop autonomous transcript movement" {
    const session = try fixture();
    defer session.deinit();
    try send(session, .{ .precise = true, .kinetic = true, .phase = .begin, .time_ms = 0 });
    try send(session, .{ .precise = true, .kinetic = true, .phase = .update, .delta_y = -10, .time_ms = 16 });
    try send(session, .{ .precise = true, .kinetic = true, .phase = .cancel, .time_ms = 16 });
    try std.testing.expect(!(try entry(session)).motion.active());
    try send(session, .{ .delta_y = -2 });
    try pinClock(session);
    try advance(session, 16 * std.time.ns_per_ms);
    try publish(session);
    const pane = session.gui.app.model.agentPane(Session.pane_id).?;
    const stopped = pane.transcript_scroll;
    try std.testing.expect(@import("../widgets/interaction/thread_selection.zig").enter(session.gui, pane.id));
    try std.testing.expectEqual(@as(usize, 0), session.gui.widgets.thread_scroll.len);
    try scroll.advance(session.gui, std.math.maxInt(u64));
    try std.testing.expectEqual(stopped, pane.transcript_scroll);
}

test "replacement attachments cannot inherit an old transcript trajectory" {
    const session = try fixture();
    defer session.deinit();
    try send(session, .{ .delta_y = -2 });
    try pinClock(session);
    try advance(session, 16 * std.time.ns_per_ms);
    try publish(session);
    const pane = session.gui.app.model.activeTabModel().?.find(Session.pane_id).?;
    const stopped = pane.transcript_scroll;
    const old_key = (try entry(session)).key;
    pane.attachment_generation += 1;
    try scroll.advance(session.gui, std.math.maxInt(u64));
    try std.testing.expectEqual(stopped, pane.transcript_scroll);
    try publish(session);
    try std.testing.expect(session.gui.widgets.thread_scroll.find(old_key) == null);
}

test "failed hidden frames retain motion until a successful presentation retires the pane" {
    const session = try fixture();
    defer session.deinit();
    try send(session, .{ .delta_y = -2 });
    try pinClock(session);
    try advance(session, 16 * std.time.ns_per_ms);
    try publish(session);
    const pane = session.gui.app.model.activeTabModel().?.find(Session.pane_id).?;
    const saved = (try entry(session)).*;
    pane.kind = .terminal;
    const failed = try session.gui.prepare(&session.renderer);
    try session.gui.complete(failed, false);
    try std.testing.expectEqual(@as(usize, 1), session.gui.widgets.thread_scroll.len);
    try std.testing.expectEqualDeep(saved, session.gui.widgets.thread_scroll.entries[0]);
    pane.kind = .agent;
    try advance(session, 16 * std.time.ns_per_ms);
    try std.testing.expect((try entry(session)).motion.spring.position > saved.motion.spring.position);
    pane.kind = .terminal;
    try publish(session);
    try std.testing.expectEqual(@as(usize, 0), session.gui.widgets.thread_scroll.len);
}

test "failed resized frames cannot commit new bounds or rebase active motion" {
    const session = try fixture();
    defer session.deinit();
    try send(session, .{ .delta_y = -2 });
    try pinClock(session);
    try advance(session, 16 * std.time.ns_per_ms);
    try publish(session);
    const before = (try entry(session)).*;
    const size = try session.gui.measure(&session.renderer, .{ .width = 800, .height = 800, .scale = 1 });
    try session.gui.resize(size, session.renderer.theme);
    session.gui.input.setGeometry(session.renderer.origin, size);
    const failed = try session.gui.prepare(&session.renderer);
    try session.gui.complete(failed, false);
    try std.testing.expectEqualDeep(before, (try entry(session)).*);
    try publish(session);
    try std.testing.expect((try entry(session)).limit < before.limit);
}

test "native gesture and momentum keep their original pane when the pointer crosses splits" {
    const session = try fixture();
    defer session.deinit();
    try addAgentPane(session);
    const first = try transcript(session);
    const second = try transcriptFor(session, second_pane_id);
    try sendAt(session, first, .{ .precise = true, .phase = .begin, .delta_y = -4 });
    try sendAt(session, second, .{ .precise = true, .phase = .update, .delta_y = -3 });
    try session.gui.input.acceptEvent(.{ .scroll = .{ .precise = true, .phase = .end, .x = -100, .y = -100 } });
    try session.gui.input.drain(&session.gui.app);
    try sendAt(session, second, .{ .precise = true, .momentum = .begin, .delta_y = -2 });
    try sendAt(session, second, .{ .precise = true, .momentum = .end, .delta_y = -0.5 });
    const first_pane = session.gui.app.model.agentPane(Session.pane_id).?;
    const second_pane = session.gui.app.model.agentPane(second_pane_id).?;
    try std.testing.expectApproxEqAbs(@as(f64, 9.5) / first.scroll_step, first_pane.transcript_scroll, 1e-10);
    try std.testing.expectEqual(@as(f64, 0), second_pane.transcript_scroll);
    try sendAt(session, second, .{ .precise = true, .delta_y = -1 });
    try std.testing.expectApproxEqAbs(@as(f64, 9.5) / first.scroll_step, first_pane.transcript_scroll, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1) / second.scroll_step, second_pane.transcript_scroll, 1e-10);
}

test "cancelled native gestures consume their remaining events until fresh input chooses a pane" {
    const session = try fixture();
    defer session.deinit();
    try addAgentPane(session);
    const first = try transcript(session);
    const second = try transcriptFor(session, second_pane_id);
    try sendAt(session, first, .{ .precise = true, .phase = .begin, .delta_y = -4 });
    try sendAt(session, first, .{ .precise = true, .phase = .cancel });
    try std.testing.expect(try scroll.captured(session.gui, .{ .precise = true, .phase = .update, .delta_y = -3, .x = -100, .y = -100 }));
    try sendAt(session, second, .{ .precise = true, .momentum = .update, .delta_y = -3 });
    const second_pane = session.gui.app.model.agentPane(second_pane_id).?;
    try std.testing.expectEqual(@as(f64, 0), second_pane.transcript_scroll);
    try sendAt(session, second, .{ .precise = true, .delta_y = -3 });
    try std.testing.expectApproxEqAbs(@as(f64, 3) / second.scroll_step, second_pane.transcript_scroll, 1e-10);
}

test "animated return to the live tail adopts the latest snapshot without another input event" {
    const session = try fixture();
    defer session.deinit();
    const pane = session.gui.app.model.activeTabModel().?.find(Session.pane_id).?;
    const window = try std.testing.allocator.create(client.AgentHistoryWindow);
    window.start(pane.agent_thread.?, pane.history_generation);
    window.pages[0].has_before = false;
    pane.agent_history = window;
    try client.agent_threads.scroll(&session.gui.app, pane.id, 1);
    try publish(session);

    var snapshot = pane.agent_thread.?.*;
    snapshot.revision = 2;
    const appended = "\nLatest output";
    @memcpy(snapshot.text_storage[snapshot.text_len..][0..appended.len], appended);
    snapshot.text_len += appended.len;
    snapshot.item_storage[0].text_len += appended.len;
    var wire: [65536]u8 = undefined;
    const encoded = try core.encodeAgentThreadSnapshot(&wire, &snapshot);
    _ = try client.server_messages.handleServerMessage(&session.gui.app, try core.decodeServer(encoded));
    try std.testing.expectEqual(@as(u64, 1), window.live_revision);
    try std.testing.expectEqual(@as(f64, 1), pane.transcript_scroll);

    try send(session, .{ .delta_y = 1 });
    try pinClock(session);
    try advance(session, 2 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(f64, 0), pane.transcript_scroll);
    try std.testing.expectEqual(@as(u64, 1), window.live_revision);
    try publish(session);
    try std.testing.expectEqual(@as(u64, 2), window.live_revision);
    try publish(session);
    try std.testing.expectEqual(@as(f64, 0), pane.transcript_scroll);
    try std.testing.expect(!(try entry(session)).motion.active());
}
