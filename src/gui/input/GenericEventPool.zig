//! Bounded storage for borrowed text in whole composition/clipboard events.
//! The queue stores slot indices; slices are rebuilt only for synchronous drain.
const event_module = @import("event.zig");
const std = @import("std");

pub fn Type(comptime byte_capacity: usize, comptime slot_capacity: usize) type {
    return struct {
        const Pool = @This();
        const Slot = struct {
            event: event_module.Event = .{ .focus = false },
            len: usize = 0,
            used: bool = false,
        };

        /// Bytes the pool's storage needs: one payload per slot.
        pub const storage_bytes = byte_capacity * slot_capacity;

        slots: [slot_capacity]Slot = @splat(.{}),
        /// The payloads, borrowed from the owner; `storage_bytes` long. Only
        /// the bytes an admitted event copies are ever written.
        storage: []u8 = &.{},

        /// Example: `var pool: Pool = .init(storage[0..Pool.storage_bytes]);`
        pub fn init(storage: []u8) Pool {
            std.debug.assert(storage.len == storage_bytes);
            return .{
                .storage = storage,
            };
        }

        /// Copies before admission completes, without retaining native pointers.
        /// Example: `const slot = try pool.admit(event);`
        pub fn admit(self: *Pool, event: event_module.Event) !u8 {
            const bytes = payload(event);
            if (bytes.len > byte_capacity) {
                return error.InputTooLarge;
            }

            if (!std.unicode.utf8ValidateSlice(bytes)) {
                return error.InvalidUtf8;
            }

            for (&self.slots, 0..) |*slot, index| {
                if (slot.used) {
                    continue;
                }

                slot.event = withPayload(event, "");
                @memcpy(self.bytesOf(index)[0..bytes.len], bytes);
                slot.len = bytes.len;
                slot.used = true;
                return @intCast(index);
            }

            return error.NativeInputFull;
        }

        /// Example: `try dispatch(pool.view(index));`
        pub fn view(self: *const Pool, index: u8) event_module.Event {
            const slot = &self.slots[index];
            std.debug.assert(slot.used);
            return withPayload(slot.event, self.bytesOf(index)[0..slot.len]);
        }

        fn bytesOf(self: *const Pool, index: usize) []u8 {
            return self.storage[index * byte_capacity ..][0..byte_capacity];
        }

        /// Example: `pool.release(index);`
        pub fn release(self: *Pool, index: u8) void {
            std.debug.assert(self.slots[index].used);
            self.slots[index].used = false;
        }

        fn payload(event: event_module.Event) []const u8 {
            return switch (event) {
                .text => |value| value.bytes,
                .paste => |value| value,
                .composition => |value| value.text,
                .clipboard => |value| value.text,
                .accessibility => |value| value.text,
                else => "",
            };
        }

        fn withPayload(event: event_module.Event, bytes: []const u8) event_module.Event {
            var result = event;
            switch (result) {
                .text => |*value| value.bytes = bytes,
                .paste => |*value| value.* = bytes,
                .composition => |*value| value.text = bytes,
                .clipboard => |*value| value.text = bytes,
                .accessibility => |*value| value.text = bytes,
                else => {},
            }

            return result;
        }
    };
}

test "payload slots own UTF8 and reject oversized or exhausted admission atomically" {
    const Pool = Type(8, 2);
    var storage: [Pool.storage_bytes]u8 = undefined;
    var pool: Pool = .init(&storage);
    var bytes = [_]u8{ 'h', 'i' };
    const index = try pool.admit(.{ .text = .{ .bytes = &bytes, .target_id = 12, .generation = 4 } });
    @memset(&bytes, 'x');
    try std.testing.expectEqualStrings("hi", pool.view(index).text.bytes);
    try std.testing.expectEqual(@as(u64, 12), pool.view(index).text.target_id);
    try std.testing.expectError(error.InputTooLarge, pool.admit(.{ .paste = "123456789" }));
    try std.testing.expectError(error.InvalidUtf8, pool.admit(.{ .paste = "\xff" }));
    const other = try pool.admit(.{ .paste = "🌍" });
    try std.testing.expectError(error.NativeInputFull, pool.admit(.{ .paste = "a" }));
    pool.release(index);
    _ = try pool.admit(.{ .paste = "new" });
    try std.testing.expectEqualStrings("🌍", pool.view(other).paste);
}
