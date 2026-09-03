//! Routes runtime event completions to their owning application capability.

const std = @import("std");
const pane_mod = @import("../../../pane/root.zig");
const Pane = pane_mod.Pane;
const runtime_config = @import("../../config.zig");
const runtime_event = @import("../../event.zig");
const agent_event_dispatcher = @import("agent.zig");
const client_event_dispatcher = @import("client.zig");
const history_event_dispatcher = @import("history.zig");
const observability_event_dispatcher = @import("observability.zig");
const pane_event_dispatcher = @import("pane/root.zig");
const observability = @import("../../observability/root.zig");
const transport = @import("../../../transport/root.zig");

const TelemetryState = observability.telemetry.State;

const IngestTestGate = runtime_config.IngestTestGate;
const RuntimeEvent = runtime_event.Event;

/// Builds the zero-allocation runtime event dispatcher for one Application
/// type.
///
/// ```zig
/// const RuntimeEvents = Dispatcher(Application);
/// ```
pub fn Dispatcher(comptime Application: type) type {
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

        /// Starts the pane's next queued input write. Used by session restore,
        /// which queues a resume command before any client is attached.
        ///
        /// ```zig
        /// try RuntimeEvents.schedulePaneInput(&application, pane);
        /// ```
        pub fn schedulePaneInput(application: *Application, pane: *Pane) !void {
            return PaneEvents.Io.scheduleInput(application, pane);
        }

        /// Classifies one non-stop runtime event and delegates its completion to
        /// the capability that owns the affected state. The return value reports
        /// whether client shutdown delivery has completed.
        ///
        /// ```zig
        /// const should_stop = try RuntimeEvents.handle(&application, event, resources);
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
                .proxy_capture => |result| {
                    try AgentEvents.handleProxyCapture(application, result);
                },
                .agent_tick => |result| {
                    try AgentEvents.handleMaintenance(application, result);
                },
                .agent_description => |result| {
                    AgentEvents.handleDescription(application, result);
                },
                .engine_response => |result| {
                    try AgentEvents.handleEngineResponse(application, result);
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
                .checkpoint_written => |result| {
                    application.sessionCheckpointWritten(result);
                },
                .git_status => |completion| {
                    application.gitStatusCompleted(completion);
                },
            }

            return false;
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
