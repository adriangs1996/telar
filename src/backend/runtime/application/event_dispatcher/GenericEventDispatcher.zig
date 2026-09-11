const GenericAgentDispatcher = @import("GenericAgentDispatcher.zig").Type;
const GenericClientDispatcher = @import("GenericClientDispatcher.zig").Type;
const GenericHistoryDispatcher = @import("GenericHistoryDispatcher.zig").Type;
const GenericObservabilityDispatcher = @import("GenericObservabilityDispatcher.zig").Type;
const GenericPaneDispatcher = @import("pane/GenericPaneDispatcher.zig").Type;
const LocalListenerType = @import("../../../transport/LocalListener.zig");
const State = @import("../../observability/State.zig");
const IngestTestGateType = @import("../../IngestTestGate.zig");
const PaneType = @import("../../../pane/Pane.zig");
const event_module = @import("../../event.zig");
const pane_search_module = @import("../pane_search.zig");

/// Builds the zero-allocation runtime event dispatcher for one Application
/// type.
///
/// ```zig
/// const RuntimeEvents = Dispatcher(Application);
/// ```
pub fn Type(comptime Application: type) type {
    const AgentEvents = GenericAgentDispatcher(Application);
    const ClientEvents = GenericClientDispatcher(Application);
    const HistoryEvents = GenericHistoryDispatcher(Application);
    const ObservabilityEvents = GenericObservabilityDispatcher(Application);
    const PaneEvents = GenericPaneDispatcher(Application, .{
        .schedule_agent_description = AgentEvents.scheduleDescription,
    });

    return struct {
        pub const EventResources = struct {
            listener: *LocalListenerType,
            telemetry: *State,
            ingest_gate: ?*IngestTestGateType,
        };

        /// Starts the pane's next queued input write. Used by session restore,
        /// which queues a resume command before any client is attached.
        ///
        /// ```zig
        /// try RuntimeEvents.schedulePaneInput(&application, pane);
        /// ```
        /// Starts a queued transfer preparation on the pane's media actor.
        /// Example: `try RuntimeEvents.schedulePaneMedia(application, pane);`.
        pub fn schedulePaneMedia(application: *Application, pane: *PaneType) !void {
            try PaneEvents.Projection.scheduleMedia(application, pane);
        }

        pub fn schedulePaneInput(application: *Application, pane: *PaneType) !void {
            return PaneEvents.Io.scheduleInput(application, pane);
        }

        /// Classifies one non-stop runtime event and delegates its completion to
        /// the capability that owns the affected state. The return value reports
        /// whether client shutdown delivery has completed.
        ///
        /// ```zig
        /// const should_stop = try RuntimeEvents.handle(&application, event, resources);
        /// ```
        pub fn handle(application: *Application, event: event_module.Event, resources: EventResources) !bool {
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
                .plugin_effects => |result| {
                    try AgentEvents.handlePluginEffects(application, result);
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
                .metrics_sampled => |sample| ObservabilityEvents.handleMetricsSample(application, sample),
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
                .pane_search => |value| {
                    try pane_search_module.advance(application, value);
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
                .session_name => |completion| {
                    application.sessionNameCompleted(completion);
                },
            }

            return false;
        }
    };
}
