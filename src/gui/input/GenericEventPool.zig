//! Bounded storage for borrowed text in whole composition/clipboard events.
//! The queue stores slot indices; slices are rebuilt only for synchronous drain.
const Window = @import("telar-window");
const event_module = Window;
const std = @import("std");

pub fn Type(comptime byte_capacity: usize, comptime slot_capacity: usize) type {
    return struct {
        const Pool = @This();
        const Slot = struct {
            event: event_module.Input = .{ .focus = false },
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
        pub fn admit(self: *Pool, event: event_module.Input) !u8 {
            return self.admitLeaving(event, 0);
        }

        /// `admit` that leaves `spare` slots free for events only `admit`
        /// takes, so one kind of event cannot take the room another needs.
        /// Example: `const slot = try pool.admitLeaving(event, 1);`
        pub fn admitLeaving(self: *Pool, event: event_module.Input, spare: usize) !u8 {
            const bytes = event.payload();
            if (bytes.len > byte_capacity) {
                return error.InputTooLarge;
            }

            if (!std.unicode.utf8ValidateSlice(bytes)) {
                return error.InvalidUtf8;
            }

            var free: usize = 0;
            for (self.slots) |slot| {
                free += @intFromBool(!slot.used);
            }

            if (free <= spare) {
                return error.InputPoolFull;
            }

            for (&self.slots, 0..) |*slot, index| {
                if (slot.used) {
                    continue;
                }

                slot.event = event.withPayload("");
                @memcpy(self.bytesOf(index)[0..bytes.len], bytes);
                slot.len = bytes.len;
                slot.used = true;
                return @intCast(index);
            }

            unreachable;
        }

        /// Example: `try dispatch(pool.view(index));`
        pub fn view(self: *const Pool, index: u8) event_module.Input {
            const slot = &self.slots[index];
            std.debug.assert(slot.used);
            return slot.event.withPayload(self.bytesOf(index)[0..slot.len]);
        }

        fn bytesOf(self: *const Pool, index: usize) []u8 {
            return self.storage[index * byte_capacity ..][0..byte_capacity];
        }

        /// Example: `pool.release(index);`
        pub fn release(self: *Pool, index: u8) void {
            std.debug.assert(self.slots[index].used);
            self.slots[index].used = false;
        }
    };
}
