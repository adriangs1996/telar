const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Session = @import("Session.zig");
const FramePacer = @import("../FramePacer.zig");
const host_ports = @import("../host_ports.zig");

const Time = enum(u64) {
    before_input = 99 * std.time.ns_per_ms,
    input = 100 * std.time.ns_per_ms,
    after_input = 101 * std.time.ns_per_ms,
};

const Frame = enum(u64) { initial = 1, echo = 2 };

fn currentPane(session: *const Session) FramePacer.Pane {
    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    return .{
        .pane_id = pane.id,
        .attachment_generation = pane.attachment_generation,
        .frame_id = pane.applied_frame_id,
        .attached = pane.attached,
    };
}

// Keep input admission and pane resolution on the production path while
// replacing its timestamp, so scheduler delays cannot expire a test's grace.
fn noteInputAtTestTime(context: *anyopaque, pane_id: core.PaneId, _: u64) void {
    const app: *client.AttachedClient = @ptrCast(@alignCast(context));
    host_ports.presentation(app).notePaneInput(pane_id, @intFromEnum(Time.input));
}

fn begin(session: *Session) !void {
    try session.bootstrap();
    try session.receiveFrame(@intFromEnum(Frame.initial));
    try session.settle();
    session.gui.app.presentation.note_pane_input_fn = noteInputAtTestTime;
    session.driver.frame_pacer.record(&.{currentPane(session)}, @intFromEnum(Time.before_input));
    try std.testing.expect(session.driver.frame_pacer.waitUntil(&.{currentPane(session)}, @intFromEnum(Time.after_input)) != null);
}

test "native admitted terminal key admits only a newer pane frame before cadence" {
    const session = try Session.init();
    defer session.deinit();
    try begin(session);
    try session.gui.input.acceptEvent(.{ .key = .{ .code = .{ .char = .init("x") } } });
    try session.gui.input.drain(&session.gui.app);
    try session.settle();
    try std.testing.expectEqualStrings("x", session.input[0..session.input_len]);
    try std.testing.expect(session.driver.frame_pacer.waitUntil(&.{currentPane(session)}, @intFromEnum(Time.after_input)) != null);

    try session.receiveFrame(@intFromEnum(Frame.echo));
    try session.settle();
    try std.testing.expectEqual(@as(usize, 2), session.ack_count);
    try std.testing.expectEqual(@as(?u64, null), session.driver.frame_pacer.waitUntil(&.{currentPane(session)}, @intFromEnum(Time.after_input)));

    session.driver.frame_pacer.record(&.{currentPane(session)}, @intFromEnum(Time.after_input));
    try std.testing.expect(session.driver.frame_pacer.waitUntil(&.{currentPane(session)}, @intFromEnum(Time.after_input)) != null);
}

test "native terminal key release without encoded bytes grants no input grace" {
    const session = try Session.init();
    defer session.deinit();
    try begin(session);
    const delivery = try client.controllers.pane_inputs.send(&session.gui.app, .{
        .target = .focused,
        .source = .host,
        .payload = .{ .key = .{ .code = .{ .char = .init("x") }, .phase = .release } },
    });
    try std.testing.expect(delivery == null);
    try session.settle();
    try std.testing.expectEqual(@as(usize, 0), session.input_len);

    try session.receiveFrame(@intFromEnum(Frame.echo));
    try session.settle();
    try std.testing.expect(session.driver.frame_pacer.waitUntil(&.{currentPane(session)}, @intFromEnum(Time.after_input)) != null);
}

test "native rejected outbox input grants no frame grace" {
    const session = try Session.init();
    defer session.deinit();
    try begin(session);
    while (session.gui.app.runtime_transport.outbox.hasCapacity()) {
        try session.gui.app.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = Session.pane_id } });
    }

    try std.testing.expectError(error.ClientOutboxFull, client.controllers.pane_inputs.send(&session.gui.app, .{
        .target = .focused,
        .source = .host,
        .payload = .{ .key = .{ .code = .{ .char = .init("x") } } },
    }));
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
    var prospective = currentPane(session);
    prospective.frame_id = @intFromEnum(Frame.echo);
    try std.testing.expect(session.driver.frame_pacer.waitUntil(&.{prospective}, @intFromEnum(Time.after_input)) != null);
}

test "native local prefix shortcut grants no terminal frame grace" {
    const session = try Session.init();
    defer session.deinit();
    try begin(session);
    try session.gui.input.acceptEvent(.{ .key = .{ .code = client.default_prefix.code, .mods = .{ .ctrl = true } } });
    try session.gui.input.drain(&session.gui.app);
    try session.settle();
    try std.testing.expect(session.gui.projection().status_mode == .prefix);
    try std.testing.expectEqual(@as(usize, 0), session.input_len);

    try session.receiveFrame(@intFromEnum(Frame.echo));
    try session.settle();
    try std.testing.expect(session.driver.frame_pacer.waitUntil(&.{currentPane(session)}, @intFromEnum(Time.after_input)) != null);
}

test "native older GPU completion preserves a newer input hint and sends no extra ACK" {
    const session = try Session.init();
    defer session.deinit();
    try begin(session);
    const token = try session.gui.prepare(&session.renderer);
    try std.testing.expect(token != 0);
    try session.gui.input.acceptEvent(.{ .key = .{ .code = .{ .char = .init("x") } } });
    try session.gui.input.drain(&session.gui.app);
    try session.settle();
    try std.testing.expectEqualStrings("x", session.input[0..session.input_len]);
    try session.receiveFrame(@intFromEnum(Frame.echo));
    try session.settle();
    const acknowledgements = session.ack_count;
    try std.testing.expectEqual(@as(usize, 2), acknowledgements);

    try session.gui.complete(token, true);
    try session.settle();
    try std.testing.expectEqual(acknowledgements, session.ack_count);
    try std.testing.expectEqual(@as(?u64, null), session.driver.frame_pacer.waitUntil(&.{currentPane(session)}, @intFromEnum(Time.after_input)));
    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    try std.testing.expectEqual(@intFromEnum(Frame.echo), pane.pending_frame_id);

    try session.gui.complete(token, true);
    try std.testing.expectEqual(@as(?u64, null), session.driver.frame_pacer.waitUntil(&.{currentPane(session)}, @intFromEnum(Time.after_input)));
}
