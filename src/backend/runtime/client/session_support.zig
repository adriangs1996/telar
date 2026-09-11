//! One disposable runtime-side client connection and its delivery state.

const std = @import("std");
const core = @import("telar-core");
const history = @import("../../history/root.zig");
const attachment_mod = @import("../attachment/root.zig");
const delivery_mod = @import("../delivery/root.zig");

pub const Io = std.Io;

pub const Key = history.model.ClientKey;
pub const Role = enum { undecided, ui, control };

pub const PendingPaneFocus = @import("PendingPaneFocus.zig");

pub const Session = @import("Session.zig");

pub const Write = @import("Write.zig");

pub const Read = @import("Read.zig");

test "focus exchange rejects duplicate reservations and stale UI completions" {
    var session: Session = undefined;
    session.pending_pane_focus = null;
    const target: Key = .{ .id = 2, .generation = 3 };
    const pending: PendingPaneFocus = .{ .request_id = @enumFromInt(4), .pane_id = @enumFromInt(5), .pane_generation = 6, .target = target };
    try session.reserveFocus(pending);
    try std.testing.expectError(error.FocusAlreadyPending, session.reserveFocus(pending));
    var reply: core.schema.CompletePaneFocus = .{
        .requester = .{ .id = 1, .generation = 1 },
        .request_id = pending.request_id,
        .pane_id = pending.pane_id,
        .pane_generation = pending.pane_generation,
        .outcome = .focused,
        .focused_pane_id = @enumFromInt(7),
    };
    try std.testing.expect(session.acceptsFocusCompletion(target, reply));
    try std.testing.expect(!session.acceptsFocusCompletion(.{ .id = 2, .generation = 4 }, reply));
    reply.pane_generation += 1;
    try std.testing.expect(!session.acceptsFocusCompletion(target, reply));
    session.releaseFocus();
    try std.testing.expect(!session.acceptsFocusCompletion(target, reply));
    try session.reserveFocus(pending);
    session.releaseFocus();
}

test "Session keeps its bounded buffers outside client store storage" {
    const session = try Session.create(
        std.testing.allocator,
        .{ .id = 1, .generation = 1 },
        .{ .stream = undefined },
    );
    defer {
        session.delivery.deinit(std.testing.allocator);
        std.testing.allocator.free(session.receive_buffer);
        std.testing.allocator.free(session.read_buffer);
        std.testing.allocator.destroy(session);
    }

    try std.testing.expectEqual(@as(u64, 1), session.key.id);
    try std.testing.expectEqual(core.transport.max_frame_size, session.receive_buffer.len);
    try std.testing.expectEqual(core.transport.max_frame_size, session.delivery.send_buffer.len);
}
