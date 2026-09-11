const shutdown_coordinator = @import("shutdown_coordinator.zig");

pub fn Type(comptime Context: type) type {
    return struct {
        const Self = @This();

        context: *Context,
        state: *shutdown_coordinator.State,
        execute_fn: *const fn (*Context, shutdown_coordinator.Step) void,

        /// Binds one runtime and its lifecycle state to a concrete step
        /// executor. The coordinator does not own either borrow.
        ///
        /// ```zig
        /// var shutdown = Coordinator(Runtime).init(&runtime, &state, executeStep);
        /// ```
        pub fn init(context: *Context, state: *shutdown_coordinator.State, execute_fn: *const fn (*Context, shutdown_coordinator.Step) void) Self {
            return .{ .context = context, .state = state, .execute_fn = execute_fn };
        }

        /// Executes the complete teardown order at most once. The state moves
        /// to `shutting_down` before the first effect, so recursive calls are
        /// harmless, and reaches `stopped` only after the last effect.
        ///
        /// ```zig
        /// shutdown.run();
        /// ```
        pub fn run(coordinator: *Self) void {
            if (coordinator.state.* != .running) {
                return;
            }

            coordinator.state.* = .shutting_down;
            for (shutdown_coordinator.shutdown_order) |step| {
                coordinator.execute_fn(coordinator.context, step);
            }
            coordinator.state.* = .stopped;
        }
    };
}
