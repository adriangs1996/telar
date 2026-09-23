//! Optional infrastructure stop signal for one runtime instance.

const std = @import("std");

/// Waits until the borrowed queue produces one stop token.
///
/// ```zig
/// try wait(io, &queue);
/// ```
pub fn wait(io: std.Io, queue: *std.Io.Queue(u8)) !void {
    _ = try queue.getOne(io);
}

test "wait consumes one queue token" {
    const io = std.testing.io;
    var storage: [1]u8 = undefined;
    var queue: std.Io.Queue(u8) = .init(&storage);
    var pending = try io.concurrent(wait, .{ io, &queue });

    try queue.putOne(io, 7);
    try pending.await(io);
}
