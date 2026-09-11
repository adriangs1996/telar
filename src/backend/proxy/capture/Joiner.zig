const Joiner = @This();
const source_namespace = @import("table.zig");
const Entry = @import("Entry.zig");
const buffer = @import("buffer_support.zig");
const Exchange = @import("Exchange.zig");
const std = @import("std");
slots: [source_namespace.capacity]?Entry = .{null} ** source_namespace.capacity,
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
pub fn push(joiner: *Joiner, now_ms: i64, half: *buffer.Half) source_namespace.PushResult {
    const index = joiner.find(half.key) orelse joiner.empty() orelse {
        return .{ .partial = source_namespace.sideExchange(half) };
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
        return .{ .partial = source_namespace.sideExchange(half) };
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
