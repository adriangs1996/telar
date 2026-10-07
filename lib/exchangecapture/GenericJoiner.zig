//! The runtime-side table that pairs independently published halves of one
//! exchange by key, and hands back complete exchanges, or partial ones after
//! a deadline.
const std = @import("std");
const Key = @import("Key.zig");
const GenericHalf = @import("GenericHalf.zig").Type;

/// A joiner for halves owned by `Meta`.
///
/// ```zig
/// const Joiner = GenericJoiner(Owner);
/// var joiner = Joiner.init(30_000);
/// ```
pub fn Type(comptime Meta: type) type {
    return struct {
        const Joiner = @This();

        pub const Half = GenericHalf(Meta);
        pub const capacity = 256;

        /// Up to two halves of one exchange, owned by whoever holds it.
        pub const Exchange = struct {
            request: ?*Half = null,
            response: ?*Half = null,

            /// Erases and frees both owned halves that are present.
            ///
            /// ```zig
            /// exchange.deinit();
            /// ```
            pub fn deinit(self: *Exchange) void {
                if (self.request) |request| {
                    request.deinit();
                }

                if (self.response) |response| {
                    response.deinit();
                }

                self.* = .{};
            }
        };

        /// What a push did with its half: kept it to wait for its peer,
        /// completed an exchange, or handed it back alone because its side
        /// was already waiting (`partial`) or every slot was taken (`full`).
        pub const PushResult = union(enum) {
            pending,
            complete: Exchange,
            partial: Exchange,
            full: Exchange,
        };

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
        pub fn push(self: *Joiner, now_ms: i64, half: *Half) PushResult {
            const index = self.find(half.key) orelse self.empty() orelse {
                return .{
                    .full = sideExchange(half),
                };
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
                return .{ .partial = sideExchange(half) };
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

        /// The exchange holding only `half`, on its own side.
        ///
        /// ```zig
        /// var exchange = Joiner.sideExchange(half);
        /// ```
        pub fn sideExchange(half: *Half) Exchange {
            return switch (half.side) {
                .request => .{ .request = half },
                .response => .{ .response = half },
            };
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
    };
}
