//! Owns one client's bounded I/O lifecycle with the runtime process.

const std = @import("std");
const core = @import("telar-core");
const client_outbox = @import("outbox.zig");

const Io = std.Io;
const schema = core.schema;

pub const capacity = client_outbox.capacity;
pub const max_input_bytes = client_outbox.max_input_bytes;
pub const Message = client_outbox.Message;
pub const Snapshot = client_outbox.Snapshot;

pub const Bootstrap = struct {
    graphics_shared: bool,
    client_identity: schema.ClientIdentity,
    terminal_colors: schema.TerminalColors = .{},
};

pub const State = struct {
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
    pub fn read(state: *State, io: Io) ![]u8 {
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
    pub fn send(state: *State, io: Io, bytes: []const u8) !void {
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
};

fn testingSocketPair() ![2]core.transport.SocketChannel {
    var sockets: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets) != 0) {
        return error.SocketPairFailed;
    }

    return .{
        .init(.{ .socket = .{
            .handle = sockets[0],
            .address = .{ .ip4 = .loopback(0) },
        } }),
        .init(.{ .socket = .{
            .handle = sockets[1],
            .address = .{ .ip4 = .loopback(0) },
        } }),
    };
}

fn initWithTestingAllocator(gpa: std.mem.Allocator) !void {
    var connection: core.transport.SocketChannel = undefined;
    var state = try State.init(gpa, &connection);
    defer state.deinit(gpa);
}

test "read reservation survives duplicate scheduling and releases on error" {
    var connection: core.transport.SocketChannel = undefined;
    var state = try State.init(std.testing.allocator, &connection);
    defer state.deinit(std.testing.allocator);
    try std.testing.expect(state.beginRead());
    try std.testing.expect(!state.beginRead());
    state.cancelRead();
    try std.testing.expect(state.beginRead());
    try std.testing.expectError(error.ReadFailed, state.completeRead(error.ReadFailed));
    try std.testing.expect(state.beginRead());
    state.cancelRead();
}

test "runtime transport releases every partial frame allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        initWithTestingAllocator,
        .{},
    );
}

test "runtime bootstrap queues colors before subscribing to the initial layout" {
    const io = std.testing.io;
    var channels = try testingSocketPair();
    defer channels[0].deinit(io);
    defer channels[1].deinit(io);
    var state = try State.init(std.testing.allocator, &channels[0]);
    defer state.deinit(std.testing.allocator);

    try state.bootstrap(.{
        .graphics_shared = true,
        .client_identity = @enumFromInt(9),
    });

    const configure = try schema.decodeClient((try state.prepareSend()).?);
    try std.testing.expect(configure == .configure_graphics);
    try std.testing.expect(configure.configure_graphics.shared);

    try state.outbox.finishSend({});
    const colors = try schema.decodeClient((try state.prepareSend()).?);
    try std.testing.expect(colors == .configure_terminal_colors);
    try state.outbox.finishSend({});

    const runtime_state = try schema.decodeClient((try state.prepareSend()).?);
    try std.testing.expect(runtime_state == .request_runtime_state);
    try std.testing.expectEqual(@as(schema.ClientIdentity, @enumFromInt(9)), runtime_state.request_runtime_state.client_identity);
}
