//! Adapters between application state and asynchronous runtime actors.

const std = @import("std");
const client_runtime = @import("../client/root.zig");
const client_session = client_runtime.session;
const runtime_config = @import("../config.zig");
const runtime_event = @import("../event.zig");
const agent_event_dispatcher = @import("event_dispatcher/agent.zig");
const client_event_dispatcher = @import("event_dispatcher/client.zig");
const history_event_dispatcher = @import("event_dispatcher/history.zig");
const observability_event_dispatcher = @import("event_dispatcher/observability.zig");
const pane_event_dispatcher = @import("event_dispatcher/pane/root.zig");
const request_dispatch = @import("request_dispatch.zig");
const observability = @import("../observability/root.zig");
const telemetry_mod = observability.telemetry;
const transport = @import("../../transport/root.zig");

const TelemetryState = telemetry_mod.State;

const IngestTestGate = runtime_config.IngestTestGate;
const RuntimeEvent = runtime_event.Event;
const ClientSession = client_session.Session;

/// Builds the zero-allocation actor bindings for one application type.
///
/// ```zig
/// const Actors = Bindings(Application);
/// ```
pub fn Bindings(comptime Application: type) type {
    const AgentEvents = agent_event_dispatcher.Dispatcher(Application);
    const ClientEvents = client_event_dispatcher.Dispatcher(Application);
    const HistoryEvents = history_event_dispatcher.Dispatcher(Application);
    const ObservabilityEvents = observability_event_dispatcher.Dispatcher(Application);
    const PaneEvents = pane_event_dispatcher.Dispatcher(Application, .{
        .schedule_agent_description = AgentEvents.scheduleDescription,
    });

    return struct {
        pub const EventResources = struct {
            listener: *transport.local.LocalListener,
            telemetry: *TelemetryState,
            ingest_gate: ?*IngestTestGate,
        };

        /// Routes one non-stop runtime event through its actor coordinator.
        ///
        /// ```zig
        /// const should_stop = try Actors.handle(&application, event, resources);
        /// ```
        pub fn handle(application: *Application, event: RuntimeEvent, resources: EventResources) !bool {
            switch (event) {
                .stopped => unreachable,
                .accepted => |result| {
                    try ClientEvents.handleAccepted(application, result, resources.listener);
                },
                .handshaken => |result| {
                    ClientEvents.handleHandshaken(application, result);
                },
                .client_message => |value| return ClientEvents.handleMessage(application, value),
                .client_sent => |value| return ClientEvents.handleSent(application, value),
                .history_response => |result| {
                    try HistoryEvents.handle(application, result);
                },
                .proxy_event => |result| {
                    try AgentEvents.handleProxyObservation(application, result);
                },
                .agent_tick => |result| {
                    try AgentEvents.handleMaintenance(application, result);
                },
                .agent_description => |result| {
                    AgentEvents.handleDescription(application, result);
                },
                .metrics_tick => |result| {
                    try ObservabilityEvents.handleMetricsTick(application, result);
                },
                .pane_input_written => |value| {
                    try PaneEvents.Io.handleInputWritten(application, value);
                },
                .pane_response_written => |value| {
                    try PaneEvents.Io.handleResponseWritten(application, value);
                },
                .pane_output => |value| {
                    try PaneEvents.Pipeline.handleOutput(application, value, resources.ingest_gate);
                },
                .pane_ingested => |value| {
                    try PaneEvents.Pipeline.handleIngested(application, value);
                },
                .pane_observed => |value| {
                    try PaneEvents.Projection.handleObserved(application, value);
                },
                .pane_media => |value| {
                    try PaneEvents.Projection.handleMedia(application, value);
                },
                .pane_exit => |value| {
                    try PaneEvents.Pipeline.handleExit(application, value);
                },
                .telemetry_tick => |result| {
                    ObservabilityEvents.handleTelemetryTick(application, resources.telemetry, result);
                },
                .telemetry_written => |result| {
                    ObservabilityEvents.handleTelemetryWritten(application, resources.telemetry, result);
                },
            }

            return false;
        }

        /// Schedules a bounded client write after delivery prepared its payload.
        ///
        /// ```zig
        /// try Actors.startSessionSend(&application, session, payload);
        /// ```
        pub fn startSessionSend(application: *Application, session: *ClientSession, payload: []const u8) !void {
            return ClientEvents.startSend(application, session, payload);
        }

        pub const request_runtime_port: request_dispatch.RuntimePort(Application) = .{
            .schedule_observation = PaneEvents.Projection.scheduleObservation,
            .schedule_media = PaneEvents.Projection.scheduleMedia,
            .schedule_response = PaneEvents.Io.scheduleResponse,
            .schedule_input = PaneEvents.Io.scheduleInput,
        };
    };
}

test {
    std.testing.refAllDecls(@This());
}
