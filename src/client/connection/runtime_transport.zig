//! Owns one client's bounded I/O lifecycle with the runtime process.

const SocketChannelType = @import("telar-core").SocketChannel;
const std = @import("std");
const RuntimeTransportState = @import("RuntimeTransportState.zig");
const decodeClient_module = @import("telar-core").decodeClient;
const ClientIdentityType = @import("telar-core").ClientIdentity;
const GenericInbox = @import("../execution/GenericInbox.zig").Type;

fn testingSocketPair() ![2]SocketChannelType {
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
    var connection: SocketChannelType = undefined;
    var state = try RuntimeTransportState.init(gpa, &connection);
    defer state.deinit(gpa);
}

test "read reservation survives duplicate scheduling and releases on error" {
    var connection: SocketChannelType = undefined;
    var state = try RuntimeTransportState.init(std.testing.allocator, &connection);
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
    var state = try RuntimeTransportState.init(std.testing.allocator, &channels[0]);
    defer state.deinit(std.testing.allocator);

    try state.bootstrap(.{
        .graphics_shared = true,
        .client_identity = @enumFromInt(9),
    });

    const configure = try decodeClient_module((try state.prepareSend()).?);
    try std.testing.expect(configure == .configure_graphics);
    try std.testing.expect(configure.configure_graphics.shared);

    try state.outbox.finishSend({});
    const colors = try decodeClient_module((try state.prepareSend()).?);
    try std.testing.expect(colors == .configure_terminal_colors);
    try state.outbox.finishSend({});

    const runtime_state = try decodeClient_module((try state.prepareSend()).?);
    try std.testing.expect(runtime_state == .request_runtime_state);
    try std.testing.expectEqual(@as(ClientIdentityType, @enumFromInt(9)), runtime_state.request_runtime_state.client_identity);
}

test "a non-reading peer cannot block receive admission or local input and shutdown joins both actors" {
    const core = @import("telar-core");
    const Event = union(enum) {
        server: anyerror!*const @import("RuntimeMessage.zig"),
        sent: anyerror!void,
        input: u8,
    };
    const io = std.testing.io;
    var channels = try testingSocketPair();
    defer channels[0].deinit(io);
    defer channels[1].deinit(io);
    var state = try RuntimeTransportState.init(std.testing.allocator, &channels[0]);
    defer state.deinit(std.testing.allocator);
    var inbox: GenericInbox(Event) = .init(io, .{});
    defer inbox.deinit();
    @memset(state.send_buffer, 0);
    try inbox.start(.sent, .{ RuntimeTransportState.send, .{ &state, io, @as([]const u8, state.send_buffer) } });
    try std.testing.expect(state.beginRead());
    try inbox.start(.server, .{ RuntimeTransportState.read, .{ &state, io } });
    try inbox.post(.{ .input = 'x' });
    var buffer: [64]u8 = undefined;
    try channels[1].send(io, try core.encodeSystemMetrics(&buffer, .{
        .revision = 7,
        .cpu_percent = 25,
        .memory_used_decigib = 10,
        .has_battery = false,
        .battery_percent = 0,
    }));
    var input_seen = false;
    var server_seen = false;
    for (0..2) |_| {
        switch (try inbox.receive()) {
            .input => |value| {
                try std.testing.expectEqual(@as(u8, 'x'), value);
                input_seen = true;
            },
            .server => |result| {
                const received = try state.completeRead(result);
                try std.testing.expectEqual(&state.received, received);
                try std.testing.expectEqual(@as(u64, 7), received.message.system_metrics.revision);
                server_seen = true;
            },
            .sent => return error.SendCompletedWithoutPeerReading,
        }
    }

    try std.testing.expect(input_seen and server_seen);
    try std.testing.expectEqual(@as(usize, 1), inbox.snapshot().reserved);
    try std.testing.expect(state.beginRead());
    try inbox.start(.server, .{ RuntimeTransportState.read, .{ &state, io } });
    inbox.deinit();
    try std.testing.expectEqual(@as(u64, 2), inbox.snapshot().stale);
    try std.testing.expectEqual(@as(usize, 0), inbox.snapshot().reserved);
}
