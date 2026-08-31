//! Application-facing boundary for starting asynchronous runtime operations.

const std = @import("std");
const client_session = @import("../client/root.zig").session;
const agent_event_dispatcher = @import("event_dispatcher/agent.zig");
const client_event_dispatcher = @import("event_dispatcher/client.zig");
const pane_event_dispatcher = @import("event_dispatcher/pane/root.zig");
const request_dispatch = @import("request_dispatch.zig");

const ClientSession = client_session.Session;

/// Builds the zero-allocation operation scheduler for one Application type.
///
/// ```zig
/// const Operations = Scheduler(Application);
/// try Operations.startSessionSend(&application, session, payload);
/// ```
pub fn Scheduler(comptime Application: type) type {
    const AgentEvents = agent_event_dispatcher.Dispatcher(Application);
    const ClientEvents = client_event_dispatcher.Dispatcher(Application);
    const PaneEvents = pane_event_dispatcher.Dispatcher(Application, .{
        .schedule_agent_description = AgentEvents.scheduleDescription,
    });

    return struct {
        /// Maps request-dispatch work to the bounded pane operation that owns
        /// its single-flight state.
        ///
        /// ```zig
        /// const RequestDispatcher = request_dispatch.Dispatcher(Application, Operations.request_runtime_port);
        /// ```
        pub const request_runtime_port: request_dispatch.RuntimePort(Application) = .{
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
        pub fn startSessionSend(application: *Application, session: *ClientSession, payload: []const u8) !void {
            return ClientEvents.startSend(application, session, payload);
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
