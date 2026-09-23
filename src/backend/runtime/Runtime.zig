const core = @import("telar-core");
const ResourcesType = @import("resources/Resources.zig");
const Loop = @import("Loop.zig");
const RuntimeModel = @import("RuntimeModel.zig");
const IngestTestGateType = @import("IngestTestGate.zig");
const InitializationType = @import("Initialization.zig");
const InitialSourcesType = @import("InitialSources.zig");
const SourcesType = @import("Sources.zig");
const runtime_event = @import("event.zig");
const events = @import("application/events.zig");
const change_review = @import("application/change_review.zig");
const agent_history = @import("application/agent_history.zig");
const agent_threads = @import("application/agent_threads.zig");
const pane_search_module = @import("application/pane_search.zig");
const editors = @import("application/operations/editors.zig");
const client_delivery = @import("application/client_delivery.zig");
/// Owns and composes the resources, event loop and model for one
/// long-lived backend lifetime.
const Runtime = @This();

resources: ResourcesType,
loop: Loop,
model: RuntimeModel,
ingest_gate: ?*IngestTestGateType,
teardown_state: enum { running, shutting_down, stopped },

/// Acquires all runtime-owned resources. The caller must keep `runtime` at
/// the same address until `deinit` completes.
///
/// ```zig
/// var runtime: Runtime = undefined;
/// try runtime.init(.{ .dependencies = dependencies, .options = options });
/// defer runtime.deinit();
/// ```
pub fn init(runtime: *Runtime, initialization: InitializationType) !void {
    try runtime.start(initialization, false);
}

pub fn start(runtime: *Runtime, initialization: InitializationType, comptime fail_after_actors: bool) !void {
    runtime.ingest_gate = initialization.options.ingest_gate;
    runtime.teardown_state = .running;

    try runtime.resources.init(initialization);
    errdefer runtime.resources.deinitUnstarted();

    runtime.loop.init(runtime.resources.io(), initialization.options.stop);
    errdefer runtime.loop.cancel();

    try runtime.model.init(&runtime.resources, runtime.loop.selector(), initialization.options);
    errdefer {
        runtime.model.panes.shutdown();
        runtime.loop.cancel();
        runtime.model.deinitModel();
    }

    runtime.model.restoreSession();
    try runtime.scheduleInitialEvents();

    if (comptime fail_after_actors) {
        return error.InjectedStartupFailure;
    }
}

fn scheduleInitialEvents(runtime: *Runtime) !void {
    var initial_sources: InitialSourcesType = .{
        .sources = SourcesType.init(runtime.resources.io(), runtime.loop.selector()),
        .listener = &runtime.resources.listener,
        .stop_signal = runtime.loop.stopCoordinator(),
        .history_service = runtime.resources.history.service(),
        .engine_service = runtime.resources.engineService(),
        .proxy_runtime = &runtime.resources.proxy,
        .plugin_service = runtime.resources.pluginService(),
        .telemetry_available = runtime.resources.telemetry.available(),
    };

    try initial_sources.schedule();
}

/// Runs the event loop until the runtime receives a stop event or an
/// infrastructure failure escapes an event entrypoint.
///
/// ```zig
/// try runtime.run();
/// ```
pub fn run(runtime: *Runtime) !void {
    while (true) {
        const event = try runtime.loop.next();
        const path = core.enter(runtime_event.diagnosticsPath(event));
        defer path.restore();

        if (try runtime.update(event)) {
            return;
        }
    }
}

/// Stops actors and releases acquired resources in dependency order. It is
/// safe to call again after teardown has completed.
///
/// ```zig
/// runtime.deinit();
/// ```
pub fn deinit(self: *Runtime) void {
    if (self.teardown_state != .running) {
        return;
    }

    self.teardown_state = .shutting_down;
    self.resources.listener.shutdown();
    self.model.stopClientConnections();
    self.model.panes.shutdown();
    // Actors must release their borrows before any backing storage is destroyed.
    self.loop.cancel();
    self.model.persistSession();

    self.resources.proxy.deinit();
    self.resources.plugins.deinit();
    self.resources.listener.deinit(self.resources.io());
    self.model.deinitClients();
    self.model.deinitModel();

    if (self.resources.engine) |*engine| {
        engine.deinit();
    }

    self.resources.history.deinit();
    self.resources.telemetry.deinit(self.resources.io());
    self.resources.child_environment.deinit();
    self.teardown_state = .stopped;
}

/// Dispatches one runtime event to its owning procedure, then flushes client
/// delivery once. Returns whether shutdown delivery has completed.
/// Example: `const stopped = try runtime.update(event);`.
pub fn update(self: *Runtime, event: runtime_event.Event) !bool {
    switch (event) {
        .stopped => |result| return self.loop.completeStop(result),
        .accepted => |result| {
            try events.clients.handleAccepted(&self.model, result, &self.resources.listener);
        },
        .handshaken => |result| {
            events.clients.handleHandshaken(&self.model, result);
        },
        .client_message => |value| events.clients.handleMessage(&self.model, value),
        .client_sent => |value| events.clients.handleSent(&self.model, value),
        .cell_publication_due => |result| {
            try self.model.cellPublicationDue(result);
        },
        .history_response => |result| {
            try events.history.handle(&self.model, result);
        },
        .proxy_event => |result| {
            try events.agents.handleProxyObservation(&self.model, result);
        },
        .proxy_capture => |result| {
            try events.agents.handleProxyCapture(&self.model, result);
        },
        .plugin_effects => |result| {
            try events.agents.handlePluginEffects(&self.model, result);
        },
        .agent_tick => |result| {
            try events.agents.handleMaintenance(&self.model, result);
        },
        .agent_description => |result| {
            events.agents.handleDescription(&self.model, result);
        },
        .change_review_completed => |job| change_review.complete(&self.model, job),
        .agent_history_completed => |job| agent_history.complete(&self.model, job),
        .agent_thread_changed => |result| {
            if (try agent_threads.handle(&self.model, result)) {
                try events.panes.Pipeline.handleExit(&self.model, .{ .pane = result.pane, .result = .{ .exited = 0 } });
            }
        },
        .engine_response => |result| {
            try events.agents.handleEngineResponse(&self.model, result);
        },
        .metrics_tick => |result| {
            try events.observability.handleMetricsTick(&self.model, result);
        },
        .metrics_sampled => |sample| events.observability.handleMetricsSample(&self.model, sample),
        .pane_input_written => |value| {
            try events.panes.Io.handleInputWritten(&self.model, value);
        },
        .pane_response_written => |value| {
            try events.panes.Io.handleResponseWritten(&self.model, value);
        },
        .pane_output => |value| {
            try events.panes.Pipeline.handleOutput(&self.model, value, self.ingest_gate);
        },
        .pane_ingested => |value| {
            try events.panes.Pipeline.handleIngested(&self.model, value);
        },
        .pane_observed => |value| {
            try events.panes.Projection.handleObserved(&self.model, value);
        },
        .pane_media => |value| {
            try events.panes.Projection.handleMedia(&self.model, value);
        },
        .pane_search => |value| {
            try pane_search_module.advance(&self.model, value);
        },
        .pane_exit => |value| {
            try events.panes.Pipeline.handleExit(&self.model, value);
        },
        .telemetry_tick => |result| {
            events.observability.handleTelemetryTick(&self.model, &self.resources.telemetry, result);
        },
        .telemetry_written => |result| {
            events.observability.handleTelemetryWritten(&self.model, &self.resources.telemetry, result);
        },
        .checkpoint_written => |result| {
            self.model.sessionCheckpointWritten(result);
        },
        .editor_opened => |job| editors.complete(&self.model, job),
        .git_status => |completion| {
            self.model.gitStatusCompleted(completion);
        },
        .session_name => |completion| {
            self.model.sessionNameCompleted(completion);
        },
    }

    try client_delivery.flush(&self.model);
    return switch (event) {
        .client_message, .client_sent => client_delivery.shutdownDelivered(&self.model),
        else => false,
    };
}
