const GenericAgentDispatcher = @import("event_dispatcher/GenericAgentDispatcher.zig").Type;
const GenericClientDispatcher = @import("event_dispatcher/GenericClientDispatcher.zig").Type;
const GenericPaneDispatcher = @import("event_dispatcher/pane/GenericPaneDispatcher.zig").Type;
const GenericRuntimePort = @import("GenericRuntimePort.zig").Type;
const Session = @import("../client/Session.zig");

/// Builds the zero-allocation operation scheduler for one Application type.
///
/// ```zig
/// const Operations = Scheduler(Application);
/// try Operations.startSessionSend(&application, session, payload);
/// ```
pub fn Type(comptime Application: type) type {
    const AgentEvents = GenericAgentDispatcher(Application);
    const ClientEvents = GenericClientDispatcher(Application);
    const PaneEvents = GenericPaneDispatcher(Application, .{
        .schedule_agent_description = AgentEvents.scheduleDescription,
    });

    return struct {
        /// Maps request-dispatch work to the bounded pane operation that owns
        /// its single-flight state.
        ///
        /// ```zig
        /// const RequestDispatcher = request_dispatch.Dispatcher(Application, Operations.request_runtime_port);
        /// ```
        pub const request_runtime_port: GenericRuntimePort(Application) = .{
            .schedule_observation = PaneEvents.Projection.scheduleObservation,
            .schedule_media = PaneEvents.Projection.scheduleMedia,
            .schedule_response = PaneEvents.Io.scheduleResponse,
            .schedule_input = PaneEvents.Io.scheduleInput,
        };

        /// Starts one bounded client write after delivery prepared its payload.
        ///
        /// ```zig
        /// try Operations.startSessionSend(&application, session, payload);
        /// ```
        pub fn startSessionSend(application: *Application, session: *Session, payload: []const u8) !void {
            return ClientEvents.startSend(application, session, payload);
        }
    };
}
