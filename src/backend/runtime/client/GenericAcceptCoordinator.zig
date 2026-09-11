const GenericAcceptPort = @import("GenericAcceptPort.zig").Type;
const GenericState = @import("GenericState.zig").Type;

/// Creates a statically dispatched accepted-socket coordinator.
///
/// ```zig
/// const AcceptedCoordinator = AcceptCoordinator(Context, Connection, port);
/// ```
pub fn Type(comptime Context: type, comptime Connection: type, comptime port: GenericAcceptPort(Context, Connection)) type {
    return struct {
        const Self = @This();
        const ConnectionState = GenericState(Connection);

        context: *Context,
        state: *ConnectionState,

        /// Binds accepted-socket effects to the runtime's handshake slot.
        ///
        /// ```zig
        /// var coordinator = AcceptedCoordinator.init(&context, &state);
        /// ```
        pub fn init(context: *Context, state: *ConnectionState) Self {
            return .{ .context = context, .state = state };
        }

        /// Rearms acceptance before starting one handshake actor. Every socket
        /// stays owned by either this call or the handshake slot; shutdown,
        /// capacity, rearm, and scheduling failures close the unclaimed socket.
        /// A new arrival aborts a stalled handshake but cannot reuse its slot
        /// until that actor completes.
        ///
        /// ```zig
        /// try coordinator.handle(accepted_result);
        /// ```
        pub fn handle(coordinator: *Self, result: anyerror!Connection) !void {
            var accepted = result catch {
                try port.rearm_accept(coordinator.context);
                return;
            };
            var accepted_owned = true;
            defer if (accepted_owned) {
                port.deinit_connection(coordinator.context, &accepted);
            };

            if (port.stopping(coordinator.context)) {
                return;
            }

            try port.rearm_accept(coordinator.context);

            if (coordinator.state.isPending()) {
                port.shutdown_connection(coordinator.context, coordinator.state.pendingConnection().?);
                return;
            }

            if (!port.has_capacity(coordinator.context)) {
                return;
            }

            coordinator.state.begin(accepted);
            accepted_owned = false;
            port.start_handshake(coordinator.context, coordinator.state.pendingConnection().?) catch {
                var unstarted = coordinator.state.takePending();
                port.deinit_connection(coordinator.context, &unstarted);
            };
        }
    };
}
