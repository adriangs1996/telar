//! Two bounded snapshots for the native renderer's single presentation in flight.

const std = @import("std");
/// Keeps prepared controls private until their frame is delivered.
/// Example: `const Presented = GenericPresentedState(HitState);`.
pub fn Type(comptime Value: type) type {
    return struct {
        const State = @This();

        slots: [2]Value = .{ .{}, .{} },
        current: u1 = 0,
        sealed: bool = false,

        /// Replaces only unpublished state, preserving the last delivered frame.
        /// Example: `const pending = state.begin();`.
        pub fn begin(self: *State) *Value {
            self.sealed = false;
            const pending = &self.slots[self.current ^ 1];
            // A large table resets its counts rather than every row.
            if (@hasDecl(Value, "reset")) {
                pending.reset();
            } else {
                pending.* = .{};
            }

            return pending;
        }

        pub fn seal(self: *State) void {
            self.sealed = true;
        }

        /// Publishes with an index change; failed frames leave controls untouched.
        /// The host validates the matching frame token before calling this method.
        /// Example: `state.present(delivered);`.
        pub fn present(self: *State, delivered: bool) void {
            if (self.sealed and delivered) {
                self.current ^= 1;
            }

            self.sealed = false;
        }

        pub fn prepared(self: *const State) *const Value {
            return &self.slots[self.current ^ 1];
        }

        /// Mutates only the unsealed replacement while its frame is prepared.
        /// Example: `try state.preparing().add(target);`
        pub fn preparing(self: *State) *Value {
            std.debug.assert(!self.sealed);
            return &self.slots[self.current ^ 1];
        }

        pub fn presented(self: *const State) *const Value {
            return &self.slots[self.current];
        }
    };
}
