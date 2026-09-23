const core = @import("telar-core");
const ResourcesType = @import("resources/Resources.zig");
const Loop = @import("Loop.zig");
const ApplicationType = @import("application/Application.zig");
const IngestTestGateType = @import("IngestTestGate.zig");
const InitializationType = @import("Initialization.zig");
const InitialSourcesType = @import("InitialSources.zig");
const SourcesType = @import("Sources.zig");
const OptionsType = @import("Options.zig");
const runtime_event = @import("event.zig");
const events = @import("application/events.zig");
const change_review = @import("application/change_review.zig");
const agent_history = @import("application/agent_history.zig");
const agent_threads = @import("application/agent_threads.zig");
const pane_search_module = @import("application/pane_search.zig");
const editors = @import("application/operations/editors.zig");
const client_delivery = @import("application/client_delivery.zig");
/// Owns and composes the resources, event loop and application for one
/// long-lived backend lifetime.
const Runtime = @This();

resources: ResourcesType,
loop: Loop,
application: ApplicationType,
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

    try runtime.composeApplication(initialization.options);
    errdefer {
        runtime.application.model.panes.shutdown();
        runtime.loop.cancel();
        runtime.application.deinitModel();
    }

    runtime.application.restoreSession();
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

fn composeApplication(runtime: *Runtime, options: OptionsType) !void {
    try runtime.application.init(.{
        .io = runtime.resources.io(),
        .gpa = runtime.resources.gpa,
        .heap = &runtime.resources.heap,
        .select = runtime.loop.selector(),
        .history_service = runtime.resources.history.service(),
        .child_environment = &runtime.resources.child_environment,
        .inherited_environment = options.environment,
        .socket_path = options.endpoint,
        .agent_manifests = &runtime.resources.agent_manifests,
        .session_path = options.session_path,
        .resume_agents = options.resume_agents,
        .proxy_runtime = &runtime.resources.proxy,
        .plugin_service = runtime.resources.pluginService(),
        .agent_description_options = options.agent_descriptions,
        .engine_service = runtime.resources.engineService(),
        .launch_fault = options.launch_fault,
        .clients = runtime.resources.clients,
        .graphics = options.graphics,
    });
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
    self.application.stopClientConnections();
    self.application.model.panes.shutdown();
    // Actors must release their borrows before any backing storage is destroyed.
    self.loop.cancel();
    self.application.persistSession();

    self.resources.proxy.deinit();
    self.resources.plugins.deinit();
    self.resources.listener.deinit(self.resources.io());
    self.application.deinitClients();
    self.application.deinitModel();

    if (self.resources.engine) |*engine| {
        engine.deinit();
    }

    self.resources.history.deinit();
    self.resources.gpa.destroy(self.resources.clients);
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
            try events.clients.handleAccepted(&self.application, result, &self.resources.listener);
        },
        .handshaken => |result| {
            events.clients.handleHandshaken(&self.application, result);
        },
        .client_message => |value| events.clients.handleMessage(&self.application, value),
        .client_sent => |value| events.clients.handleSent(&self.application, value),
        .cell_publication_due => |result| {
            try self.application.cellPublicationDue(result);
        },
        .history_response => |result| {
            try events.history.handle(&self.application, result);
        },
        .proxy_event => |result| {
            try events.agents.handleProxyObservation(&self.application, result);
        },
        .proxy_capture => |result| {
            try events.agents.handleProxyCapture(&self.application, result);
        },
        .plugin_effects => |result| {
            try events.agents.handlePluginEffects(&self.application, result);
        },
        .agent_tick => |result| {
            try events.agents.handleMaintenance(&self.application, result);
        },
        .agent_description => |result| {
            events.agents.handleDescription(&self.application, result);
        },
        .change_review_completed => |job| change_review.complete(&self.application, job),
        .agent_history_completed => |job| agent_history.complete(&self.application, job),
        .agent_thread_changed => |result| {
            if (try agent_threads.handle(&self.application, result)) {
                try events.panes.Pipeline.handleExit(&self.application, .{ .pane = result.pane, .result = .{ .exited = 0 } });
            }
        },
        .engine_response => |result| {
            try events.agents.handleEngineResponse(&self.application, result);
        },
        .metrics_tick => |result| {
            try events.observability.handleMetricsTick(&self.application, result);
        },
        .metrics_sampled => |sample| events.observability.handleMetricsSample(&self.application, sample),
        .pane_input_written => |value| {
            try events.panes.Io.handleInputWritten(&self.application, value);
        },
        .pane_response_written => |value| {
            try events.panes.Io.handleResponseWritten(&self.application, value);
        },
        .pane_output => |value| {
            try events.panes.Pipeline.handleOutput(&self.application, value, self.ingest_gate);
        },
        .pane_ingested => |value| {
            try events.panes.Pipeline.handleIngested(&self.application, value);
        },
        .pane_observed => |value| {
            try events.panes.Projection.handleObserved(&self.application, value);
        },
        .pane_media => |value| {
            try events.panes.Projection.handleMedia(&self.application, value);
        },
        .pane_search => |value| {
            try pane_search_module.advance(&self.application, value);
        },
        .pane_exit => |value| {
            try events.panes.Pipeline.handleExit(&self.application, value);
        },
        .telemetry_tick => |result| {
            events.observability.handleTelemetryTick(&self.application, &self.resources.telemetry, result);
        },
        .telemetry_written => |result| {
            events.observability.handleTelemetryWritten(&self.application, &self.resources.telemetry, result);
        },
        .checkpoint_written => |result| {
            self.application.sessionCheckpointWritten(result);
        },
        .editor_opened => |job| editors.complete(&self.application, job),
        .git_status => |completion| {
            self.application.gitStatusCompleted(completion);
        },
        .session_name => |completion| {
            self.application.sessionNameCompleted(completion);
        },
    }

    try client_delivery.flush(&self.application);
    return switch (event) {
        .client_message, .client_sent => client_delivery.shutdownDelivered(&self.application),
        else => false,
    };
}
