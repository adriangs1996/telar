const table = @import("table.zig");
const Half = @import("Half.zig");
const Exchange = @import("Exchange.zig");
const Key = @import("Key.zig");
const std = @import("std");
const Joiner = @This();

slots: [table.capacity]?Entry = .{null} ** table.capacity,
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
pub fn deinit(self: *Joiner) void {
    for (&self.slots) |*slot| {
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
pub fn push(self: *Joiner, now_ms: i64, half: *Half) table.PushResult {
    const index = self.find(half.key) orelse self.empty() orelse {
        return .{ .partial = table.sideExchange(half) };
    };
    var entry = self.slots[index] orelse Entry{
        .key = half.key,
        .expires_at_ms = now_ms + self.timeout_ms,
    };

    const duplicate = switch (half.side) {
        .request => entry.request != null,
        .response => entry.response != null,
    };
    if (duplicate) {
        return .{ .partial = table.sideExchange(half) };
    }

    switch (half.side) {
        .request => entry.request = half,
        .response => entry.response = half,
    }

    if (entry.request != null and entry.response != null) {
        self.slots[index] = null;
        return .{ .complete = entry.exchange() };
    }

    self.slots[index] = entry;
    return .pending;
}

/// Removes one expired partial exchange for caller-owned disposal.
///
/// ```zig
/// if (joiner.expire(now_ms)) |exchange| { _ = exchange; }
/// ```
pub fn expire(self: *Joiner, now_ms: i64) ?Exchange {
    for (&self.slots) |*slot| {
        const entry = slot.* orelse continue;
        if (entry.expires_at_ms > now_ms) {
            continue;
        }

        slot.* = null;
        return entry.exchange();
    }

    return null;
}

fn find(self: *const Joiner, key: Key) ?usize {
    for (self.slots, 0..) |slot, index| {
        const entry = slot orelse continue;
        if (std.meta.eql(entry.key, key)) {
            return index;
        }
    }

    return null;
}

fn empty(self: *const Joiner) ?usize {
    for (self.slots, 0..) |slot, index| {
        if (slot == null) {
            return index;
        }
    }

    return null;
}

const Entry = struct {
    key: Key,
    request: ?*Half = null,
    response: ?*Half = null,
    expires_at_ms: i64,

    pub fn exchange(self: Entry) Exchange {
        return .{ .request = self.request, .response = self.response };
    }
};
