const GenericTelemetryTickCoordinatorRuntimePort = @import("GenericTelemetryTickCoordinatorRuntimePort.zig").Type;
const source_namespace = @import("telemetry_tick_coordinator.zig");
/// Creates a statically dispatched telemetry-tick coordinator.
///
/// ```zig
/// const TelemetryTickCoordinator = Coordinator(Context, port);
/// ```
pub fn Type(comptime Context: type, comptime port: GenericTelemetryTickCoordinatorRuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        state: *source_namespace.State,

        /// Binds one runtime's sampling effects to its telemetry state.
        ///
        /// ```zig
        /// var coordinator = TelemetryTickCoordinator.init(&context, &state);
        /// ```
        pub fn init(context: *Context, state: *source_namespace.State) Self {
            return .{ .context = context, .state = state };
        }

        /// Rearms the periodic tick before sampling. Samples coalesce while a
        /// write owns the shared buffer; scheduler failures retire the sink,
        /// while formatting failures only discard the current sample.
        ///
        /// ```zig
        /// coordinator.handle(tick_result);
        /// ```
        pub fn handle(coordinator: *Self, result: anyerror!void) void {
            result catch {
                port.disable(coordinator.context, coordinator.state);
                return;
            };

            if (!port.available(coordinator.context, coordinator.state)) {
                return;
            }

            port.schedule_tick(coordinator.context) catch {
                port.disable(coordinator.context, coordinator.state);
                return;
            };

            if (coordinator.state.writePending()) {
                return;
            }

            const line = port.format_sample(coordinator.context, coordinator.state.buffer()) catch return;
            coordinator.state.beginWrite();
            port.schedule_write(coordinator.context, coordinator.state, line) catch {
                coordinator.state.cancelWrite();
                port.disable(coordinator.context, coordinator.state);
            };
        }
    };
}
