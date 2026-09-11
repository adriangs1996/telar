//! Owns one client's bounded I/O lifecycle with the runtime process.

const SocketChannelType = @import("telar-core").SocketChannel;
const std = @import("std");
const RuntimeTransportState = @import("RuntimeTransportState.zig");
const decodeClient_module = @import("telar-core").decodeClient;
const ClientIdentityType = @import("telar-core").ClientIdentity;

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
