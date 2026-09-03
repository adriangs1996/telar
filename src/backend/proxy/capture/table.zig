//! Runtime-side pairing table for independently published capture halves.

const std = @import("std");
const buffer = @import("buffer.zig");

pub const capacity = 256;

pub const Exchange = struct {
    request: ?*buffer.Half = null,
    response: ?*buffer.Half = null,

    /// Erases and frees both owned halves that are present.
    ///
    /// ```zig
    /// exchange.deinit();
    /// ```
    pub fn deinit(exchange: *Exchange) void {
        if (exchange.request) |request| {
            request.deinit();
        }

        if (exchange.response) |response| {
            response.deinit();
        }

        exchange.* = .{};
    }
};

pub const PushResult = union(enum) {
    pending,
    complete: Exchange,
    partial: Exchange,
};

const Entry = struct {
    key: buffer.Key,
    request: ?*buffer.Half = null,
    response: ?*buffer.Half = null,
    expires_at_ms: i64,

    fn exchange(entry: Entry) Exchange {
        return .{ .request = entry.request, .response = entry.response };
    }
};

pub const Joiner = struct {
    slots: [capacity]?Entry = .{null} ** capacity,
    timeout_ms: u32,

    /// Creates an empty fixed-capacity join table.
    ///
    /// ```zig
    /// var joiner = Joiner.init(30_000);
    /// ```
    pub fn init(timeout_ms: u32) Joiner {
        return .{ .timeout_ms = timeout_ms };
    }

    /// Releases every half still waiting for its peer.
    ///
    /// ```zig
    /// defer joiner.deinit();
    /// ```
    pub fn deinit(joiner: *Joiner) void {
        for (&joiner.slots) |*slot| {
            if (slot.*) |entry| {
                var exchange = entry.exchange();
                exchange.deinit();
                slot.* = null;
            }
        }
    }

    /// Transfers one half into the table or returns an owned exchange result.
    ///
    /// ```zig
    /// const result = joiner.push(now_ms, half);
    /// ```
    pub fn push(joiner: *Joiner, now_ms: i64, half: *buffer.Half) PushResult {
        const index = joiner.find(half.key) orelse joiner.empty() orelse {
            return .{ .partial = sideExchange(half) };
        };
        var entry = joiner.slots[index] orelse Entry{
            .key = half.key,
            .expires_at_ms = now_ms + joiner.timeout_ms,
        };

        const duplicate = switch (half.side) {
            .request => entry.request != null,
            .response => entry.response != null,
        };
        if (duplicate) {
            return .{ .partial = sideExchange(half) };
        }

        switch (half.side) {
            .request => entry.request = half,
            .response => entry.response = half,
        }

        if (entry.request != null and entry.response != null) {
            joiner.slots[index] = null;
            return .{ .complete = entry.exchange() };
        }

        joiner.slots[index] = entry;
        return .pending;
    }

    /// Removes one expired partial exchange for caller-owned disposal.
    ///
    /// ```zig
    /// if (joiner.expire(now_ms)) |exchange| { _ = exchange; }
    /// ```
    pub fn expire(joiner: *Joiner, now_ms: i64) ?Exchange {
        for (&joiner.slots) |*slot| {
            const entry = slot.* orelse continue;
            if (entry.expires_at_ms > now_ms) {
                continue;
            }

            slot.* = null;
            return entry.exchange();
        }

        return null;
    }

    fn find(joiner: *const Joiner, key: buffer.Key) ?usize {
        for (joiner.slots, 0..) |slot, index| {
            const entry = slot orelse continue;
            if (std.meta.eql(entry.key, key)) {
                return index;
            }
        }

        return null;
    }

    fn empty(joiner: *const Joiner) ?usize {
        for (joiner.slots, 0..) |slot, index| {
            if (slot == null) {
                return index;
            }
        }

        return null;
    }
};

fn sideExchange(half: *buffer.Half) Exchange {
    return switch (half.side) {
        .request => .{ .request = half },
        .response => .{ .response = half },
    };
}

fn testHalf(quota: *buffer.Quota, side: buffer.Side) *buffer.Half {
    const credential: @import("../identity.zig").Credential = .{
        .pane_id = @enumFromInt(7),
        .pane_generation = 1,
        .token = .{0x5a} ** @import("../identity.zig").token_bytes,
    };

    return buffer.Half.create(.{
        .gpa = std.testing.allocator,
        .quota = quota,
        .config = .{
            .enabled = true,
            .max_part_bytes = 8,
            .max_exchange_bytes = 16,
            .max_total_bytes = 16,
        },
        .credential = credential,
        .dialect = .unknown,
        .protocol = .h2,
        .key = .{ .connection_id = 3, .stream_id = 5 },
        .side = side,
        .host = "example.test",
        .started_at_ms = 1,
    }).?;
}

test "joiner pairs independently delivered request and response halves" {
    var quota = buffer.Quota.init(16);
    var joiner = Joiner.init(30);
    defer joiner.deinit();

    try std.testing.expectEqual(PushResult.pending, joiner.push(10, testHalf(&quota, .response)));
    var exchange = switch (joiner.push(11, testHalf(&quota, .request))) {
        .complete => |value| value,
        else => return error.ExpectedCompleteCapture,
    };
    defer exchange.deinit();
    try std.testing.expect(exchange.request != null);
    try std.testing.expect(exchange.response != null);
}

test "joiner returns a partial exchange only after its deadline" {
    var quota = buffer.Quota.init(16);
    var joiner = Joiner.init(30);
    defer joiner.deinit();

    try std.testing.expectEqual(PushResult.pending, joiner.push(10, testHalf(&quota, .request)));
    try std.testing.expect(joiner.expire(39) == null);
    var exchange = joiner.expire(40).?;
    defer exchange.deinit();
    try std.testing.expect(exchange.request != null);
    try std.testing.expect(exchange.response == null);
}
