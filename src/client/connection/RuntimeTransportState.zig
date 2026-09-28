const localsocket = @import("localsocket");
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const State = @This();

/// The connected socket; null while the client has none.
connection: ?*localsocket.SocketChannel,
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
    const connection = self.connection orelse return error.NotConnected;
    const bytes = try connection.receive(io, self.receive_buffer);
    core.mark(io, .client_read);
    try self.received.decodeInto(io, bytes);
    return &self.received;
}

/// Sends the reserved frame without knowing the client event protocol.
/// Example: `try state.send(io, bytes);`.
pub fn send(self: *State, io: std.Io, bytes: []const u8) !void {
    const connection = self.connection orelse return error.NotConnected;
    try connection.send(io, bytes);
}

/// Starts using a connected channel; its reads go through this state's
/// buffer. No read or write may be in flight.
///
/// ```zig
/// state.bind(&client.channel);
/// ```
pub fn bind(self: *State, connection: *localsocket.SocketChannel) void {
    std.debug.assert(!self.receive_pending);
    connection.bindReadBuffer(self.read_buffer);
    self.connection = connection;
}

/// Stops using the channel, which the caller then closes. No read or write
/// may be in flight.
///
/// ```zig
/// state.unbind();
/// ```
pub fn unbind(self: *State) void {
    const connection = self.connection orelse return;
    connection.bindReadBuffer(&.{});
    self.connection = null;
}

/// Allocates the bounded frame buffers, around a connected channel when
/// there is one.
///
/// ```zig
/// var state = try State.init(gpa, connection);
/// ```
pub fn init(gpa: std.mem.Allocator, connection: ?*localsocket.SocketChannel) !State {
    const receive_buffer = try gpa.alloc(u8, localsocket.transport.max_frame_size);
    errdefer gpa.free(receive_buffer);
    const read_buffer = try gpa.alloc(u8, localsocket.transport.read_buffer_size);
    errdefer gpa.free(read_buffer);
    const send_buffer = try gpa.alloc(u8, localsocket.transport.max_frame_size);
    if (connection) |channel| {
        channel.bindReadBuffer(read_buffer);
    }

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
    self.unbind();
    gpa.free(self.send_buffer);
    gpa.free(self.receive_buffer);
    gpa.free(self.read_buffer);
}
