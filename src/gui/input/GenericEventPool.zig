//! Bounded storage for borrowed text in whole composition/clipboard events.
//! The queue stores slot indices; slices are rebuilt only for synchronous drain.
const std = @import("std");
const Event = @import("event.zig").Event;

pub fn Type(comptime byte_capacity: usize, comptime slot_capacity: usize) type {
    return struct {
        const Pool = @This();
        const Slot = struct {
            event: Event = .{ .focus = false },
            bytes: [byte_capacity]u8 = undefined,
            len: usize = 0,
            used: bool = false,
        };

        slots: [slot_capacity]Slot = @splat(.{}),

        /// Copies before admission completes, without retaining native pointers.
        /// Example: `const slot = try pool.admit(event);`
        pub fn admit(pool: *Pool, event: Event) !u8 {
            const bytes = payload(event);
            if (bytes.len > byte_capacity) {
                return error.InputTooLarge;
            }

            if (!std.unicode.utf8ValidateSlice(bytes)) {
                return error.InvalidUtf8;
            }

            for (&pool.slots, 0..) |*slot, index| {
                if (slot.used) {
                    continue;
                }

                slot.event = withPayload(event, "");
                @memcpy(slot.bytes[0..bytes.len], bytes);
                slot.len = bytes.len;
                slot.used = true;
                return @intCast(index);
            }

            return error.NativeInputFull;
        }

        /// Example: `try dispatch(pool.view(index));`
        pub fn view(pool: *const Pool, index: u8) Event {
            const slot = &pool.slots[index];
            std.debug.assert(slot.used);
            return withPayload(slot.event, slot.bytes[0..slot.len]);
        }

        /// Example: `pool.release(index);`
        pub fn release(pool: *Pool, index: u8) void {
            std.debug.assert(pool.slots[index].used);
            pool.slots[index].used = false;
        }

        fn payload(event: Event) []const u8 {
            return switch (event) {
                .text => |value| value.bytes,
                .paste => |value| value,
                .composition => |value| value.text,
                .clipboard => |value| value.text,
                .accessibility => |value| value.text,
                else => "",
            };
        }

        fn withPayload(event: Event, bytes: []const u8) Event {
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
    var pool: Type(8, 2) = .{};
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
