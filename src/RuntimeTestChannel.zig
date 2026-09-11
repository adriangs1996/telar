/// Runtime integration reads must fail instead of hanging the whole test
/// process. A timeout makes the framed stream unusable because the reader may
/// have consumed part of a frame, so the failure path shuts the channel down.
const RuntimeTestChannel = @This();
const core = @import("telar-core");
const std = @import("std");
const source_namespace = @import("transport_integration_test.zig");
channel: core.transport.SocketChannel,

pub fn send(self: *RuntimeTestChannel, io: std.Io, payload: []const u8) !void {
    return self.channel.send(io, payload);
}

pub fn receive(self: *RuntimeTestChannel, io: std.Io, buffer: []u8) ![]u8 {
    var storage: [2]source_namespace.TestReceiveEvent = undefined;
    var select = std.Io.Select(source_namespace.TestReceiveEvent).init(io, &storage);
    defer select.cancelDiscard();
    try select.concurrent(.received, source_namespace.receiveRuntimeFrame, .{ io, &self.channel, buffer });
    try select.concurrent(.expired, source_namespace.waitForTestReceiveDeadline, .{io});
    return switch (try select.await()) {
        .received => |result| try result,
        .expired => |result| {
            try result;
            self.channel.shutdown(io);
            return error.TestReceiveDeadlineExceeded;
        },
    };
}

pub fn deinit(self: *RuntimeTestChannel, io: std.Io) void {
    self.channel.deinit(io);
}
