//! A resolver for tests that answers only once the test opens its gate, as
//! the system resolver waits for a network that is down, and a table whose
//! workers call it. Storage is static, like the table proxies use, so a
//! worker still blocked when a test fails touches nothing freed.
const std = @import("std");
const name_resolution = @import("name_resolution.zig");
const Resolutions = @import("Resolutions.zig");
const HostName = std.Io.net.HostName;
const IpAddress = std.Io.net.IpAddress;

/// A table whose workers block until `open`.
pub var table: Resolutions = .{
    .resolver = answerOnceOpen,
};

var gate: std.Io.Event = .unset;
var calls: std.atomic.Value(u32) = .init(0);

/// Blocks until `open`, then answers every name with the loopback address.
///
/// ```zig
/// var resolutions: Resolutions = .{ .resolver = gated_resolver.answerOnceOpen };
/// ```
pub fn answerOnceOpen(host: HostName, addresses: []IpAddress) Resolutions.Failure!usize {
    _ = host;
    _ = calls.fetchAdd(1, .monotonic);
    gate.waitUncancelable(std.testing.io);
    addresses[0] = .{
        .ip4 = .loopback(0),
    };

    return 1;
}

/// Opens the gate without waiting for the workers, for a test that reads
/// their answer.
///
/// ```zig
/// gated_resolver.answer();
/// ```
pub fn answer() void {
    gate.set(std.testing.io);
}

/// Lets every blocked worker of `resolutions` return, waits until each
/// freed its row, and closes the gate again for the next test.
///
/// ```zig
/// try gated_resolver.open(&gated_resolver.table);
/// ```
pub fn open(resolutions: *const Resolutions) !void {
    answer();
    try expectDrained(resolutions);
    gate.reset();
    calls.store(0, .monotonic);
}

/// Waits until every row of `resolutions` is free.
///
/// ```zig
/// try gated_resolver.expectDrained(&resolutions);
/// ```
pub fn expectDrained(resolutions: *const Resolutions) !void {
    for (0..poll_count) |_| {
        if (resolutions.count(.free) == Resolutions.capacity) {
            return;
        }

        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }

    return error.ResolutionsNotDrained;
}

/// Waits until the gated resolver has been called `expected` times since
/// the gate last closed.
///
/// ```zig
/// try gated_resolver.expectCalls(1);
/// ```
pub fn expectCalls(expected: u32) !void {
    for (0..poll_count) |_| {
        if (calls.load(.monotonic) == expected) {
            return;
        }

        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }

    return error.ResolverCallsNotObserved;
}

/// Waits until `expected` tunnels wait for `name` in the gated table.
///
/// ```zig
/// try gated_resolver.expectWaiters("shared.test", 8);
/// ```
pub fn expectWaiters(name: []const u8, expected: u32) !void {
    const io = std.testing.io;
    const host = HostName.init(name) catch unreachable;

    for (0..poll_count) |_| {
        table.lock();
        const waiting = if (table.find(host, io)) |slot| table.waiters[@intFromEnum(slot)] else 0;
        table.unlock();

        if (waiting == expected) {
            return;
        }

        try io.sleep(.fromMilliseconds(1), .awake);
    }

    return error.ResolutionWaitersNotObserved;
}

/// Resolves `name` in the gated table, waiting at most `wait_ms`.
///
/// ```zig
/// try std.testing.expectError(error.Timeout, gated_resolver.resolve("silent.test", 50));
/// ```
pub fn resolve(name: []const u8, wait_ms: i64) name_resolution.Error!usize {
    const io = std.testing.io;
    var addresses: [Resolutions.max_addresses]IpAddress = undefined;

    return name_resolution.resolve(
        &table,
        .{
            .host = HostName.init(name) catch unreachable,
            .io = io,
            .deadline_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds() + wait_ms,
        },
        &addresses,
    );
}

/// Takes every row of the gated table with a name whose tunnel already gave
/// up, as after an outage longer than the establishment deadline.
///
/// ```zig
/// try gated_resolver.fill();
/// ```
pub fn fill() !void {
    var buffer: [32]u8 = undefined;
    for (0..Resolutions.capacity) |index| {
        const name = try std.fmt.bufPrint(&buffer, "silent-{d}.test", .{index});
        try std.testing.expectError(error.Timeout, resolve(name, 0));
    }

    try std.testing.expectEqual(Resolutions.capacity, table.count(.resolving));
}

/// How many times a wait polls, a millisecond apart, before it fails.
const poll_count = 2000;
