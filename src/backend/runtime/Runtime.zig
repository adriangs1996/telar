const core = @import("telar-core");
const Resources = @import("resources/Resources.zig");
const Loop = @import("Loop.zig");
const RuntimeModel = @import("RuntimeModel.zig");
const Initialization = @import("Initialization.zig");
const Sources = @import("Sources.zig");
const runtime_event = @import("event.zig");
const agent_description = @import("agent_description.zig");
const agent_history = @import("agent_history.zig");
const agent_maintenance = @import("agent_maintenance.zig");
const agent_panes = @import("agent_panes.zig");
const agent_rename = @import("agent_rename.zig");
const change_review = @import("change_review.zig");
const client_connection = @import("client_connection.zig");
const client_delivery = @import("client_delivery.zig");
const command_history = @import("command_history.zig");
const link_opening = @import("link_opening.zig");
const pane_closure = @import("pane_closure.zig");
const pane_graphics = @import("pane_graphics.zig");
const pane_input = @import("pane_input.zig");
const pane_observation = @import("pane_observation.zig");
const pane_output = @import("pane_output.zig");
const pane_search = @import("pane_search.zig");
const proxy_capture = @import("proxy_capture.zig");
const proxy_observation = @import("proxy_observation.zig");
const proxy_tap = @import("proxy_tap.zig");
const runtime_telemetry = @import("runtime_telemetry.zig");
const session_checkpoint = @import("session_checkpoint.zig");
const suggest_command = @import("suggest_command.zig");
const system_metrics = @import("system_metrics.zig");
const workspace_git = @import("workspace_git.zig");
/// Owns and composes the resources, event loop and model for one
/// long-lived backend lifetime.
const Runtime = @This();

resources: Resources,
loop: Loop,
model: RuntimeModel,
teardown_state: enum { running, shutting_down, stopped },

/// Acquires all runtime-owned resources. The caller must keep `runtime` at
/// the same address until `deinit` completes.
///
/// ```zig
/// var runtime: Runtime = undefined;
/// try runtime.init(.{ .dependencies = dependencies, .options = options });
/// defer runtime.deinit();
/// ```
pub fn init(runtime: *Runtime, initialization: Initialization) !void {
    try runtime.start(initialization, false);
}

pub fn start(runtime: *Runtime, initialization: Initialization, comptime fail_after_actors: bool) !void {
    runtime.teardown_state = .running;

    try runtime.resources.init(initialization);
    errdefer runtime.resources.deinitUnstarted();

    runtime.loop.init(runtime.resources.io(), initialization.options.stop);
    errdefer runtime.loop.cancel();

    try runtime.model.init(&runtime.resources, runtime.loop.selector(), initialization.options);
    errdefer {
        runtime.model.panes.shutdown();
        runtime.loop.cancel();
        runtime.model.deinit();
    }

    session_checkpoint.restore(&runtime.model);
    try runtime.scheduleInitialEvents();

    if (comptime fail_after_actors) {
        return error.InjectedStartupFailure;
    }
}

fn scheduleInitialEvents(runtime: *Runtime) !void {
    const resources = &runtime.resources;
    var sources = Sources.init(resources.io(), runtime.loop.selector());

    try sources.acceptClient(&resources.listener);
    try sources.waitForStop(runtime.loop.stop);
    try sources.receiveHistory(resources.history.service());
    if (resources.engineService()) |engine_service| {
        try sources.receiveEngine(engine_service);
    }
    try sources.receiveProxyObservation(&resources.proxy);
    try sources.receiveProxyCapture(&resources.proxy);
    try sources.receivePluginEffects(resources.pluginService());
    try sources.waitForAgentMaintenance();
    try sources.waitForSystemMetrics();

    if (comptime core.enabled) {
        if (resources.telemetry.available()) {
            try sources.waitForTelemetry();
        }
    }
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
    client_connection.shutdownAll(&self.model);
    self.model.panes.shutdown();
    // Actors must release their borrows before any backing storage is destroyed.
    self.loop.cancel();
    self.model.checkpoint.discardJoinedWrite();
    session_checkpoint.writeNow(&self.model);

    self.resources.proxy.deinit();
    self.resources.plugins.deinit();
    self.resources.listener.deinit(self.resources.io());
    client_connection.releaseAll(&self.model);
    self.model.deinit();

    if (self.resources.engine) |*engine| {
        engine.deinit();
    }

    self.resources.history.deinit();
    self.resources.telemetry.deinit(self.resources.io());
    self.resources.child_environment.deinit();
    self.teardown_state = .stopped;
}

/// Calls the procedure that owns one runtime event, then flushes client
/// delivery once. Returns whether shutdown delivery has completed.
/// Example: `const stopped = try runtime.update(event);`.
pub fn update(self: *Runtime, event: runtime_event.Event) !bool {
    const model = &self.model;
    switch (event) {
        .stopped => |result| return self.loop.completeStop(result),
        .accepted => |result| try client_connection.accept(model, result, &self.resources.listener),
        .handshaken => |result| client_connection.finishHandshake(model, result),
        .client_message => |message| client_connection.receive(model, message),
        .client_sent => |sent| client_connection.finishSend(model, sent),
        .cell_publication_due => |result| try model.cell_timer.complete(result),
        .pane_output => |completion| try pane_output.receive(model, completion),
        .pane_ingested => |completion| try pane_output.finishIngest(model, completion),
        .pane_input_written => |completion| try pane_input.finishInputWrite(model, completion),
        .pane_response_written => |completion| try pane_input.finishResponseWrite(model, completion),
        .pane_observed => |completion| try pane_observation.finish(model, completion),
        .pane_media => |completion| try pane_graphics.finishMedia(model, completion),
        .pane_search => |wake| try pane_search.advance(model, wake),
        .pane_exit => |completion| try pane_closure.finishExit(model, completion),
        .agent_thread_changed => |completion| try agent_panes.receive(model, completion),
        .agent_history_completed => |job| agent_history.finish(model, job),
        .agent_description => |result| agent_description.finish(model, result),
        .agent_tick => |result| try agent_maintenance.tick(model, result),
        .session_name => |completion| agent_rename.finish(model, completion),
        .proxy_event => |result| try proxy_observation.receive(model, result),
        .proxy_capture => |result| try proxy_capture.receive(model, result),
        .plugin_effects => |result| try proxy_tap.receive(model, result),
        .engine_response => |result| try suggest_command.finish(model, result),
        .change_review_completed => |job| change_review.finish(model, job),
        .editor_opened => |job| link_opening.finish(model, job),
        .history_response => |result| try command_history.receive(model, result),
        .git_status => |completion| workspace_git.finish(model, completion),
        .checkpoint_written => |result| session_checkpoint.finish(model, result),
        .metrics_tick => |result| try system_metrics.tick(model, result),
        .metrics_sampled => |sample| system_metrics.finish(model, sample),
        .telemetry_tick => |result| runtime_telemetry.tick(model, &self.resources.telemetry, result),
        .telemetry_written => |result| runtime_telemetry.finish(model, &self.resources.telemetry, result),
    }

    try client_delivery.flush(model);
    return switch (event) {
        .client_message, .client_sent => client_delivery.shutdownDelivered(model),
        else => false,
    };
}
