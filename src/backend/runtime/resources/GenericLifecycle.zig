const GenericPort = @import("GenericPort.zig").Type;
/// Owns one started worker and its state until `deinit`.
///
/// ```zig
/// const ServiceLifecycle = Lifecycle(State, Worker, port);
/// var lifecycle = try ServiceLifecycle.start(state);
/// defer lifecycle.deinit();
/// ```
pub fn Type(comptime StateType: type, comptime WorkerType: type, comptime port: GenericPort(StateType, WorkerType)) type {
    return struct {
        const Self = @This();

        state: *StateType,
        worker: WorkerType,

        pub fn start(state: *StateType) !Self {
            errdefer port.destroy(state);

            return .{
                .state = state,
                .worker = try port.start(state),
            };
        }

        pub fn deinit(lifecycle: *Self) void {
            port.close(lifecycle.state);
            port.join(lifecycle.state, &lifecycle.worker);
            port.destroy(lifecycle.state);
        }
    };
}
