const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const State = @This();

connection: *core.SocketChannel,
send_buffer: []u8,
receive_buffer: []u8,
read_buffer: []u8,
received: data.RuntimeMessage = undefined,
receive_pending: bool = false,

/// Reserves the single receive buffer before a read actor starts.
/// Example: `if (!state.beginRead()) return;`.
pub fn beginRead(self: *State) bool {
    if (self.receive_pending) {
        return false;
    }

    self.receive_pending = true;
    return true;
}

/// Releases a read that could not be scheduled.
/// Example: `state.cancelRead();`.
pub fn cancelRead(self: *State) void {
    self.receive_pending = false;
}

/// Releases the read reservation. The returned borrow lasts until the next
/// read, which the consumer arms only after dispatch finishes.
/// Example: `const payload = try state.completeRead(result);`.
pub fn completeRead(self: *State, result: anyerror!*const data.RuntimeMessage) !*const data.RuntimeMessage {
    std.debug.assert(self.receive_pending);
    self.receive_pending = false;
    return result;
}

/// Owns the decoded value beside its wire bytes until dispatch finishes.
/// Inbox messages borrow this value; they do not duplicate it in every slot.
/// Example: `return state.read(io);`.
pub fn read(self: *State, io: std.Io) !*const data.RuntimeMessage {
    const bytes = try self.connection.receive(io, self.receive_buffer);
    core.mark(io, .client_read);
    self.received = try data.RuntimeMessage.decode(io, bytes);
    return &self.received;
}

/// Sends the reserved frame without knowing the client event protocol.
/// Example: `try state.send(io, bytes);`.
pub fn send(self: *State, io: std.Io, bytes: []const u8) !void {
    try self.connection.send(io, bytes);
}

/// Allocates the bounded frame buffers around one connected channel.
///
/// ```zig
/// var state = try State.init(gpa, connection);
/// ```
pub fn init(gpa: std.mem.Allocator, connection: *core.SocketChannel) !State {
    const receive_buffer = try gpa.alloc(u8, core.max_frame_size);
    errdefer gpa.free(receive_buffer);
    const read_buffer = try gpa.alloc(u8, core.read_buffer_size);
    errdefer gpa.free(read_buffer);
    const send_buffer = try gpa.alloc(u8, core.max_frame_size);
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
pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
    self.connection.bindReadBuffer(&.{});
    gpa.free(self.send_buffer);
    gpa.free(self.receive_buffer);
    gpa.free(self.read_buffer);
}
