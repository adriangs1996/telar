//! Two bounded snapshots for the native renderer's single presentation in flight.

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
        pub fn begin(state: *State) *Value {
            state.sealed = false;
            state.slots[state.current ^ 1] = .{};
            return &state.slots[state.current ^ 1];
        }

        pub fn seal(state: *State) void {
            state.sealed = true;
        }

        /// Publishes with an index change; failed frames leave controls untouched.
        /// The host validates the matching frame token before calling this method.
        /// Example: `state.present(delivered);`.
        pub fn present(state: *State, delivered: bool) void {
            if (state.sealed and delivered) {
                state.current ^= 1;
            }

            state.sealed = false;
        }

        pub fn prepared(state: *const State) *const Value {
            return &state.slots[state.current ^ 1];
        }

        /// Mutates only the unsealed replacement while its frame is prepared.
        /// Example: `try state.preparing().add(target);`
        pub fn preparing(state: *State) *Value {
            @import("std").debug.assert(!state.sealed);
            return &state.slots[state.current ^ 1];
        }

        pub fn presented(state: *const State) *const Value {
            return &state.slots[state.current];
        }
    };
}
