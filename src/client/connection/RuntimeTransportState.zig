const State = @This();
const core = @import("telar-core");
const client_outbox = @import("outbox_support.zig");
const std = @import("std");
const source_namespace = @import("runtime_transport.zig");
const Bootstrap = @import("Bootstrap.zig");
connection: *core.transport.SocketChannel,
send_buffer: []u8,
receive_buffer: []u8,
read_buffer: []u8,
outbox: client_outbox.Outbox = .{},
receive_pending: bool = false,

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

/// Retires the read borrow before delivering its result.
/// Example: `const payload = try state.completeRead(result);`.
pub fn completeRead(state: *State, result: anyerror![]u8) ![]u8 {
    std.debug.assert(state.receive_pending);
    state.receive_pending = false;
    return result;
}

/// Reads into the reserved bounded frame buffer on the I/O actor.
/// Example: `return state.read(io);`.
pub fn read(state: *State, io: source_namespace.Io) ![]u8 {
    return state.connection.receive(io, state.receive_buffer);
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
pub fn send(state: *State, io: source_namespace.Io, bytes: []const u8) !void {
    try state.connection.send(io, bytes);
}

/// Allocates the bounded frame buffers around one connected channel.
///
/// ```zig
/// var state = try State.init(gpa, connection);
/// ```
pub fn init(gpa: std.mem.Allocator, connection: *core.transport.SocketChannel) !State {
    const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    errdefer gpa.free(receive_buffer);
    const read_buffer = try gpa.alloc(u8, core.transport.read_buffer_size);
    errdefer gpa.free(read_buffer);
    const send_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    connection.bindReadBuffer(read_buffer);

    return .{
        .connection = connection,
        .send_buffer = send_buffer,
        .receive_buffer = receive_buffer,
        .read_buffer = read_buffer,
    };
}

/// Releases frame storage after the client's select has cancelled every
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
