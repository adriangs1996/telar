const GenericHandshakePort = @import("GenericHandshakePort.zig").Type;
const GenericState = @import("GenericState.zig").Type;
/// Creates a statically dispatched handshake-completion coordinator.
///
/// ```zig
/// const HandshakenCoordinator = HandshakeCoordinator(Context, Types, port);
/// ```
pub fn Type(comptime Context: type, comptime Types: type, comptime port: GenericHandshakePort(Context, Types)) type {
    return struct {
        const Self = @This();
        const ConnectionState = GenericState(Types.Connection);

        context: *Context,
        state: *ConnectionState,

        /// Binds handshake completion to the runtime's admission slot.
        ///
        /// ```zig
        /// var coordinator = HandshakenCoordinator.init(&context, &state);
        /// ```
        pub fn init(context: *Context, state: *ConnectionState) Self {
            return .{ .context = context, .state = state };
        }

        /// Releases the actor slot before interpreting its result. Failed or
        /// shutdown handshakes close the negotiated socket; successful
        /// admission transfers ownership to a session, whose first-read
        /// scheduling failure removes that complete session.
        ///
        /// ```zig
        /// coordinator.handle(handshake_result);
        /// ```
        pub fn handle(coordinator: *Self, result: anyerror!void) void {
            var negotiated = coordinator.state.takePending();
            var connection_owned = true;
            defer if (connection_owned) {
                port.deinit_connection(coordinator.context, &negotiated);
            };

            result catch return;

            if (port.stopping(coordinator.context)) {
                return;
            }

            const session = port.admit(coordinator.context, negotiated) catch return;
            connection_owned = false;
            port.start_receive(coordinator.context, session) catch {
                port.drop_session(coordinator.context, session);
            };
        }
    };
}
