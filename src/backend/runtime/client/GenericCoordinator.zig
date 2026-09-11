const GenericRuntimePort = @import("GenericRuntimePort.zig").Type;
const GenericSentEvent = @import("GenericSentEvent.zig").Type;

/// Creates a statically dispatched client-send completion coordinator.
///
/// ```zig
/// const ClientSendCoordinator = Coordinator(Context, Types, port);
/// ```
pub fn Type(comptime Context: type, comptime Types: type, comptime port: GenericRuntimePort(Context, Types)) type {
    return struct {
        const Self = @This();
        const Event = GenericSentEvent(Types);

        context: *Context,

        /// Binds send-completion policy to one runtime instance.
        ///
        /// ```zig
        /// var coordinator = ClientSendCoordinator.init(&context);
        /// ```
        pub fn init(context: *Context) Self {
            return .{ .context = context };
        }

        /// Releases the completed send borrow before applying delivery state.
        /// Closing and failed clients are finalized first; successful effects
        /// apply deferred detach and close-after-reply policy before retrying
        /// delivery. During shutdown, the return value reports whether every
        /// client has received or abandoned its stopping message.
        ///
        /// ```zig
        /// if (coordinator.handle(event)) {
        ///     return;
        /// }
        /// ```
        pub fn handle(coordinator: *Self, event: Event) bool {
            const session = port.resolve(coordinator.context, event.client) orelse {
                port.record_stale(coordinator.context);
                return false;
            };

            port.release_send(coordinator.context, session);
            if (port.is_closing(coordinator.context, session)) {
                port.finalize(coordinator.context, event.client);
                return port.shutdown_delivered(coordinator.context);
            }

            const completion = port.complete_delivery(coordinator.context, session, event.result);
            if (completion.close_client) {
                port.drop_client(coordinator.context, event.client);
                return port.shutdown_delivered(coordinator.context);
            }

            if (completion.detach_pane) |detach| {
                port.detach_after_send(coordinator.context, session, detach);
            }

            if (port.should_close_after_reply(coordinator.context, session) and
                !port.stopping(coordinator.context))
            {
                port.drop_client(coordinator.context, event.client);
                return false;
            }

            port.pump_client(coordinator.context, session) catch {
                port.drop_client(coordinator.context, event.client);
            };

            if (!port.stopping(coordinator.context)) {
                return false;
            }

            port.pump_all(coordinator.context);
            return port.shutdown_delivered(coordinator.context);
        }
    };
}
