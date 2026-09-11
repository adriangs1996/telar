const std = @import("std");

/// Creates the runtime-owned slot borrowed by one in-flight handshake actor.
///
/// ```zig
/// const AdmissionState = State(Connection);
/// var state: AdmissionState = .{};
/// ```
pub fn Type(comptime Connection: type) type {
    return struct {
        const Self = @This();

        slot: ?Connection = null,
        pending: bool = false,

        /// Reports whether a handshake actor still borrows the connection.
        ///
        /// ```zig
        /// if (state.isPending()) {
        ///     return;
        /// }
        /// ```
        pub fn isPending(state: *const Self) bool {
            return state.pending;
        }

        /// Returns the connection borrowed by the active handshake, if any.
        /// Shutdown may use it to unblock the actor but must not deinitialize it.
        ///
        /// ```zig
        /// if (state.pendingConnection()) |connection| {
        ///     connection.shutdown(io);
        /// }
        /// ```
        pub fn pendingConnection(state: *Self) ?*Connection {
            if (!state.pending) {
                return null;
            }

            return &state.slot.?;
        }

        /// Transfers the pending connection out after its actor has completed
        /// or failed to start, leaving the slot idle for the next admission.
        ///
        /// ```zig
        /// var connection = state.takePending();
        /// defer connection.deinit(io);
        /// ```
        pub fn takePending(state: *Self) Connection {
            std.debug.assert(state.pending and state.slot != null);
            const connection = state.slot.?;
            state.slot = null;
            state.pending = false;
            return connection;
        }

        pub fn begin(state: *Self, connection: Connection) void {
            std.debug.assert(!state.pending and state.slot == null);
            state.slot = connection;
            state.pending = true;
        }
    };
}
