const SocketChannelType = @import("telar-core").SocketChannel;
const OutboxType = @import("Outbox.zig");
const std = @import("std");
const max_frame_size_module = @import("telar-core").max_frame_size;
const read_buffer_size_module = @import("telar-core").read_buffer_size;
const Bootstrap = @import("Bootstrap.zig");
const RuntimeMessage = @import("RuntimeMessage.zig");
const TransportDriver = @import("TransportDriver.zig");
const State = @This();

connection: *SocketChannelType,
send_buffer: []u8,
receive_buffer: []u8,
read_buffer: []u8,
received: RuntimeMessage = undefined,
outbox: OutboxType = .{},
receive_pending: bool = false,

/// Reserves one read and releases the reservation if the driver rejects it.
/// Example: `try state.scheduleRead(driver);`
pub fn scheduleRead(self: *State, driver: TransportDriver) !void {
    if (!self.beginRead()) {
        return;
    }

    driver.startRead(self) catch |err| {
        self.cancelRead();

        return err;
    };
}

/// Starts the next queued frame, retaining it for retry if scheduling fails.
/// Example: `try state.pump(driver);`
pub fn pump(self: *State, driver: TransportDriver) !void {
    const payload = try self.prepareSend() orelse return;

    driver.startSend(self, payload) catch |err| {
        self.cancelSend();

        return err;
    };
}

/// Reserves the single receive buffer before a read actor starts.
/// Example: `if (!state.beginRead()) return;`.
pub fn beginRead(state: *State) bool {
    if (state.receive_pending) {
        return false;
    }

    state.receive_pending = true;
    return true;
}

/// Releases a read that could not be scheduled.
/// Example: `state.cancelRead();`.
pub fn cancelRead(state: *State) void {
    state.receive_pending = false;
}

/// Releases the read reservation. The returned borrow lasts until the next
/// read, which the consumer arms only after dispatch finishes.
/// Example: `const payload = try state.completeRead(result);`.
pub fn completeRead(state: *State, result: anyerror!*const RuntimeMessage) !*const RuntimeMessage {
    std.debug.assert(state.receive_pending);
    state.receive_pending = false;
    return result;
}

/// Owns the decoded value beside its wire bytes until dispatch finishes.
/// Inbox messages borrow this value; they do not duplicate it in every slot.
/// Example: `return state.read(io);`.
pub fn read(state: *State, io: std.Io) !*const RuntimeMessage {
    const bytes = try state.connection.receive(io, state.receive_buffer);
    @import("telar-core").mark(io, .client_read);
    state.received = try RuntimeMessage.decode(io, bytes);
    return &state.received;
}

/// Reserves and encodes the next outbound frame for its send actor.
/// Example: `const bytes = try state.prepareSend() orelse return;`.
pub fn prepareSend(state: *State) !?[]const u8 {
    return state.outbox.beginSend(state.send_buffer);
}

/// Releases a send that could not be scheduled.
/// Example: `state.cancelSend();`.
pub fn cancelSend(state: *State) void {
    state.outbox.sendFailed();
}

/// Sends the reserved frame without knowing the client event protocol.
/// Example: `try state.send(io, bytes);`.
pub fn send(state: *State, io: std.Io, bytes: []const u8) !void {
    try state.connection.send(io, bytes);
}

/// Allocates the bounded frame buffers around one connected channel.
///
/// ```zig
/// var state = try State.init(gpa, connection);
/// ```
pub fn init(gpa: std.mem.Allocator, connection: *SocketChannelType) !State {
    const receive_buffer = try gpa.alloc(u8, max_frame_size_module);
    errdefer gpa.free(receive_buffer);
    const read_buffer = try gpa.alloc(u8, read_buffer_size_module);
    errdefer gpa.free(read_buffer);
    const send_buffer = try gpa.alloc(u8, max_frame_size_module);
    connection.bindReadBuffer(read_buffer);

    return .{
        .connection = connection,
        .send_buffer = send_buffer,
        .receive_buffer = receive_buffer,
        .read_buffer = read_buffer,
    };
}

/// Releases frame storage after the client's inbox has joined every
/// task that borrows it.
///
/// ```zig
/// state.deinit(gpa);
/// ```
pub fn deinit(state: *State, gpa: std.mem.Allocator) void {
    state.connection.bindReadBuffer(&.{});
    gpa.free(state.send_buffer);
    gpa.free(state.receive_buffer);
    gpa.free(state.read_buffer);
}

/// Queues one ordered bootstrap after host negotiation. Capacity is checked
/// before any frame is queued; the ordinary send actor owns all writes.
///
/// ```zig
/// try state.bootstrap(bootstrap);
/// ```
pub fn bootstrap(state: *State, request: Bootstrap) !void {
    if (state.outbox.availableCapacity() < 3) {
        return error.ClientOutboxFull;
    }

    try state.outbox.push(.{ .configure_graphics = .{ .shared = request.graphics_shared } });
    try state.outbox.push(.{ .configure_terminal_colors = request.terminal_colors });
    try state.outbox.push(.{ .request_runtime_state = .{ .client_identity = request.client_identity } });
}

test "transport scheduling releases rejected reservations and retries queued frames in order" {
    const Driver = struct {
        reject: bool = true,
        reads: usize = 0,
        sends: usize = 0,
        payload: []const u8 = &.{},

        fn read(raw: *anyopaque, state: *State) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.reads += 1;
            try std.testing.expect(state.receive_pending);

            if (self.reject) {
                return error.DriverBusy;
            }
        }

        fn send(raw: *anyopaque, state: *State, payload: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.sends += 1;
            self.payload = payload;
            try std.testing.expect(state.outbox.inFlight());

            if (self.reject) {
                return error.DriverBusy;
            }
        }
    };

    var capture: Driver = .{};
    const driver: TransportDriver = .{
        .context = &capture,
        .start_read_fn = Driver.read,
        .start_send_fn = Driver.send,
    };
    var send_buffer: [64]u8 = undefined;
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{
        .connection = undefined,
        .send_buffer = &send_buffer,
        .receive_buffer = &.{},
        .read_buffer = &.{},
    };

    try std.testing.expectError(error.DriverBusy, state.scheduleRead(driver));
    try std.testing.expect(!state.receive_pending);
    capture.reject = false;
    try state.scheduleRead(driver);
    try state.scheduleRead(driver);
    try std.testing.expectEqual(@as(usize, 2), capture.reads);
    try std.testing.expectError(error.ReadFailed, state.completeRead(error.ReadFailed));
    try std.testing.expect(!state.receive_pending);
    try state.scheduleRead(driver);
    try std.testing.expectEqual(@as(usize, 3), capture.reads);
    state.cancelRead();

    try state.pump(driver);
    try std.testing.expectEqual(@as(usize, 0), capture.sends);
    try state.outbox.push(
        .{
            .detach_pane = .{
                .pane_id = @enumFromInt(1),
            },
        },
    );
    try state.outbox.push(
        .{
            .detach_pane = .{
                .pane_id = @enumFromInt(2),
            },
        },
    );
    capture.reject = true;
    try std.testing.expectError(error.DriverBusy, state.pump(driver));
    try std.testing.expect(!state.outbox.inFlight());
    try std.testing.expectEqual(@as(u8, 2), state.outbox.len);
    const first = send_buffer;
    const first_len = capture.payload.len;
    capture.reject = false;
    try state.pump(driver);
    try std.testing.expectEqualSlices(
        u8,
        first[0..first_len],
        capture.payload,
    );
    try state.pump(driver);
    try std.testing.expectEqual(@as(usize, 2), capture.sends);
    try state.outbox.finishSend({});
    try state.pump(driver);
    try std.testing.expectEqual(@as(usize, 3), capture.sends);
    try std.testing.expect(!std.mem.eql(
        u8,
        first[0..first_len],
        capture.payload,
    ));
    try state.outbox.finishSend({});
    try std.testing.expectEqual(@as(u8, 0), state.outbox.len);
}
