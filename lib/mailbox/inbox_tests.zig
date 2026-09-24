const std = @import("std");
const GenericInbox = @import("GenericInbox.zig").Type;
const Budget = @import("DrainBudget.zig");
const Ticket = @import("ProducerTicket.zig");
const Event = union(enum) { value: u32, focus: bool, completed: anyerror!void };
const Inbox = GenericInbox(Event);

fn number(value: u32) u32 {
    return value;
}

fn waitForStop(io: std.Io, ready: *std.Io.Event) anyerror!void {
    try ready.wait(io);
}

test "inbox reserves completion capacity before starting work" {
    var inbox: Inbox = .init(std.testing.io, .{});
    defer inbox.deinit();
    var tickets: [Inbox.capacity]Ticket = undefined;
    for (&tickets) |*ticket| {
        ticket.* = try inbox.reserve();
    }

    try std.testing.expectError(error.InboxFull, inbox.post(.{ .value = 99 }));
    try std.testing.expectError(error.InboxFull, inbox.start(.value, .{ number, .{@as(u32, 99)} }));
    try std.testing.expectEqual(@as(usize, 0), inbox.snapshot().depth);
    for (tickets, 0..) |ticket, index| {
        try std.testing.expect(inbox.publish(ticket, .{ .value = @intCast(index) }));
    }

    for (0..Inbox.capacity) |index| {
        try std.testing.expectEqual(@as(u32, @intCast(index)), (try inbox.receive()).value);
    }

    try inbox.start(.value, .{ number, .{@as(u32, 100)} });
    try std.testing.expectEqual(@as(u32, 100), (try inbox.receive()).value);
    try std.testing.expectEqual(@as(u64, 2), inbox.snapshot().rejected);
}

test "stale duplicate and closed producer tickets cannot publish into a reused slot" {
    var inbox: Inbox = .init(std.testing.io, .{});
    defer inbox.deinit();
    const old = try inbox.reserve();
    inbox.release(old);
    const replacement = try inbox.reserve();
    try std.testing.expectEqual(old.slot, replacement.slot);
    try std.testing.expect(!inbox.publish(old, .{ .value = 1 }));
    try std.testing.expect(inbox.publish(replacement, .{ .value = 2 }));
    try std.testing.expect(!inbox.publish(replacement, .{ .value = 3 }));
    try std.testing.expectEqual(@as(u32, 2), (try inbox.receive()).value);
    const late = try inbox.reserve();
    inbox.close();
    try std.testing.expect(!inbox.publish(late, .{ .value = 4 }));
    try std.testing.expectError(error.InboxClosed, inbox.post(.{ .value = 5 }));
    try std.testing.expectError(error.InboxClosed, inbox.wait());
    try std.testing.expectError(error.InboxClosed, inbox.receive());
}

test "a drain has a finite boundary even when handling a message publishes more work" {
    var inbox: Inbox = .init(std.testing.io, .{});
    defer inbox.deinit();
    try inbox.post(.{ .value = 1 });
    var turn = try inbox.begin();
    try std.testing.expectError(error.ReentrantClientDispatch, inbox.begin());
    try std.testing.expectEqual(@as(u32, 1), (try inbox.next(&turn)).?.value);
    try inbox.post(.{ .value = 2 });
    try std.testing.expectEqual(@as(?Event, null), try inbox.next(&turn));
    inbox.end();
    try std.testing.expectEqual(@as(usize, 1), inbox.snapshot().depth);
    try std.testing.expectEqual(@as(u64, 1), inbox.snapshot().budget_yields);
    try std.testing.expectEqual(@as(u32, 2), (try inbox.receive()).value);
}

test "message and time budgets yield while retaining every accepted message" {
    var inbox: Inbox = .init(std.testing.io, .{});
    defer inbox.deinit();
    for (0..Inbox.capacity) |index| {
        try inbox.post(.{ .value = @intCast(index) });
    }

    var turn = try inbox.begin();
    try std.testing.expectEqual(Budget.max_messages, turn.remaining);
    _ = try inbox.next(&turn);
    turn.started_ns -= Budget.max_duration_ns;
    try std.testing.expectEqual(@as(?Event, null), try inbox.next(&turn));
    inbox.end();
    try std.testing.expectEqual(Inbox.capacity - 1, inbox.snapshot().depth);
    for (1..Inbox.capacity) |index| {
        try std.testing.expectEqual(@as(u32, @intCast(index)), (try inbox.receive()).value);
    }
}

test "wakeups coalesce while accepted FIFO messages remain distinct" {
    var inbox: Inbox = .init(std.testing.io, .{});
    defer inbox.deinit();
    try inbox.post(.{ .value = 1 });
    try inbox.post(.{ .value = 2 });
    try inbox.notify(.{ .focus = true });
    try inbox.notify(.{ .focus = false });
    try std.testing.expectEqual(@as(u64, 1), inbox.snapshot().wakes);
    try std.testing.expectEqual(@as(usize, 3), inbox.snapshot().depth);
    try std.testing.expectEqual(@as(u32, 1), (try inbox.receive()).value);
    try std.testing.expectEqual(@as(u32, 2), (try inbox.receive()).value);
    try std.testing.expect(!(try inbox.receive()).focus);
    try std.testing.expect(!inbox.ready.isSet());
    try inbox.post(.{ .value = 3 });
    try std.testing.expectEqual(@as(u64, 2), inbox.snapshot().wakes);
    try inbox.wait();
    _ = try inbox.receive();
}

test "closing a saturated inbox cancels its producer without waiting for a consumer" {
    var inbox: Inbox = .init(std.testing.io, .{});
    var ready: std.Io.Event = .unset;
    try inbox.start(.completed, .{ waitForStop, .{ std.testing.io, &ready } });
    for (0..Inbox.capacity - 1) |index| {
        try inbox.post(.{ .value = @intCast(index) });
    }

    inbox.deinit();
    try std.testing.expectEqual(@as(u64, 1), inbox.snapshot().stale);
}

test "concurrent producers publish once and cannot lose a wake while draining" {
    var inbox: Inbox = .init(std.testing.io, .{});
    defer inbox.deinit();
    for (0..16) |index| {
        try inbox.start(.value, .{ number, .{@as(u32, @intCast(index))} });
    }

    var seen: u16 = 0;
    for (0..16) |_| {
        const message = try inbox.receive();
        const bit = @as(u16, 1) << @as(u4, @intCast(message.value));
        try std.testing.expect(seen & bit == 0);
        seen |= bit;
    }

    try std.testing.expectEqual(std.math.maxInt(u16), seen);
    try std.testing.expectEqual(@as(usize, 0), inbox.snapshot().reserved);
    try std.testing.expectEqual(@as(usize, 0), inbox.snapshot().depth);
}
