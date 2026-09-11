const source_namespace = @import("shutdown_coordinator.zig");
pub fn Type(comptime Context: type) type {
    return struct {
        const Self = @This();

        context: *Context,
        state: *source_namespace.State,
        execute_fn: *const fn (*Context, source_namespace.Step) void,

        /// Binds one runtime and its lifecycle state to a concrete step
        /// executor. The coordinator does not own either borrow.
        ///
        /// ```zig
        /// var shutdown = Coordinator(Runtime).init(&runtime, &state, executeStep);
        /// ```
        pub fn init(context: *Context, state: *source_namespace.State, execute_fn: *const fn (*Context, source_namespace.Step) void) Self {
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
            for (source_namespace.shutdown_order) |step| {
                coordinator.execute_fn(coordinator.context, step);
            }
            coordinator.state.* = .stopped;
        }
    };
}
