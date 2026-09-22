const core = @import("telar-core");
const proxy_observation = @import("../../entrypoints/events/proxy_observation.zig");
const PaneKeyType = @import("../../../pane/PaneKey.zig");
const RecordCommandType = @import("../../../plugins/RecordCommand.zig");
const AgentEvidenceType = @import("../../../plugins/AgentEvidence.zig");
const agent_identity = @import("../coordinators/agent_identity.zig");
const PluginNotification = @import("../../../plugins/Notification.zig");
const ObservationType = @import("../../../proxy/Observation.zig");
const Half = @import("../../../proxy/capture/Half.zig");
const ResultType = @import("../../../plugins/Result.zig");
const AgentResult = @import("../../../agent/Result.zig");
const ResponseType = @import("../../../engine/Response.zig");
const SourcesType = @import("../../Sources.zig");
const types = @import("../../../engine/types.zig");
const PendingSuggestionType = @import("../../delivery/PendingSuggestion.zig");
const suggestion = @import("../suggestion.zig");
const CommandType = @import("../../../agent/Command.zig");
const JobType = @import("../../../agent/Job.zig");
const std = @import("std");
const description_module = @import("../../../agent/description.zig");
const DescriptionFinishedType = @import("../../../agent/DescriptionFinished.zig");

const Application = @import("../Application.zig");

/// Applies one proxy observation to its agent and rearms proxy receive.
///
/// ```zig
/// try AgentEvents.handleProxyObservation(&application, result);
/// ```
pub fn handleProxyObservation(application: *Application, result: anyerror!ObservationType) !void {
    const event = result catch return;
    try rearmProxyObservation(application);

    const pane = application.model.panes.resolve(event.pane) orelse {
        application.metrics.stale_pane_events += 1;
        return;
    };

    if (comptime core.enabled) {
        application.metrics.proxy_observations +|= 1;
    }

    const observation = proxy_observation.translate(event, pane) orelse return;
    _ = application.model.agents.observeProxy(observation);
    scheduleDescription(application);
    application.pumpAll();
}

pub fn handleProxyCapture(application: *Application, result: anyerror!*Half) !void {
    const half = result catch return;
    errdefer half.deinit();
    try rearmProxyCapture(application);

    const key: PaneKeyType = .{ .id = half.pane.id, .generation = half.pane.generation };
    if (application.model.panes.resolve(key) == null) {
        half.deinit();
        return;
    }

    application.proxy_runtime.decodeCapture(half);
    application.proxy_runtime.acceptCapture(.{
        .now_ms = (std.Io.Timestamp.now(application.io, .real).toMilliseconds()),
        .half = half,
    });
}

/// Authorizes and applies one bounded effect batch, then rearms receive.
///
/// ```zig
/// try AgentEvents.handlePluginEffects(&application, result);
/// ```
pub fn handlePluginEffects(application: *Application, result_value: anyerror!*ResultType) !void {
    const result = result_value catch return;
    defer result.deinit();
    try rearmPluginEffects(application);
    application.plugin_service.authorize(result) catch return;

    var changed = false;
    for (result.batch.slice()) |effect| switch (effect) {
        .record_command => |record| recordPluginCommand(application, result, record),
        .agent_evidence => |evidence| changed = applyPluginEvidence(application, evidence) or changed,
        .notification => |notification| {
            if (publishPluginEffectNotification(application, notification)) {
                changed = true;
            }
        },
    };

    if (changed) {
        application.pumpAll();
    }
}

/// Applies one maintenance tick, expires stale agent activity and
/// rearms the periodic source.
///
/// ```zig
/// try AgentEvents.handleMaintenance(&application, result);
/// ```
pub fn handleMaintenance(application: *Application, result: anyerror!void) !void {
    try maintainAgents(application, result);
    try application.flushSessionCheckpoint();
    application.tickGitStatus();
    application.tickSessionNames();
    checkEngineIdle(application);
    application.proxy_runtime.expireCaptures((std.Io.Timestamp.now(application.io, .real).toMilliseconds()));
}

/// Applies one generated description and persists the resulting title.
///
/// ```zig
/// AgentEvents.handleDescription(&application, result);
/// ```
pub fn handleDescription(application: *Application, result: AgentResult) void {
    application.agent_description_state.complete();
    _ = commitDescription(application, result);
    _ = startNextDescription(application);
    application.pumpAll();
}

/// Starts the next queued agent-description job when the configured
/// generator and coordinator state permit it.
///
/// ```zig
/// AgentEvents.scheduleDescription(&application);
/// ```
pub fn scheduleDescription(application: *Application) void {
    _ = startNextDescription(application);
}

/// Applies one engine reply and rearms the engine receive.
///
/// ```zig
/// try AgentEvents.handleEngineResponse(&application, result);
/// ```
pub fn handleEngineResponse(application: *Application, result: anyerror!ResponseType) !void {
    const response = result catch return;
    const service = application.engine_service orelse return;
    var sources = SourcesType.init(application.io, application.select);
    try sources.receiveEngine(service);

    switch (response.purpose) {
        .suggestion => |target| deliverSuggestion(application, target, &response),
    }
}

/// Answers the client that asked for a suggestion, if it is still
/// connected; a departed client simply drops the reply.
fn deliverSuggestion(application: *Application, target: types.Purpose.Suggestion, response: *const ResponseType) void {
    const session = application.clients.resolve(.{ .id = target.client_id, .generation = target.client_generation }) orelse return;
    var pending: PendingSuggestionType = .{
        .request_id = @enumFromInt(target.request_id),
        .status = switch (response.status) {
            .success => .ready,
            .unavailable => .unavailable,
            .timeout => .timeout,
            .invalid_output, .failed => .failed,
        },
    };
    if (pending.status == .ready) {
        if (suggestion.extractCommand(response.textSlice())) |command| {
            @memcpy(pending.text[0..command.len], command);
            pending.text_len = @intCast(command.len);
        } else {
            pending.status = .failed;
        }
    }

    session.delivery.responses.push(.{ .command_suggestion = pending }) catch return;
    application.pumpAll();
}

/// Asks the engine to kill its child when it has been idle. Called
/// from the agent maintenance tick; it queues nothing when no child
/// is alive.
///
/// ```zig
/// AgentEvents.checkEngineIdle(&application);
/// ```
pub fn checkEngineIdle(application: *Application) void {
    const service = application.engine_service orelse return;
    service.requestIdleCheck(application.io);
}

fn startAgentDescription(application: *Application, command: CommandType, job_value: JobType) !void {
    var job = job_value;
    defer std.crypto.secureZero(u8, &job.query);

    try application.select.concurrent(
        .agent_description,
        description_module.generate,
        .{ application.io, application.gpa, .{ .command = command, .job = job } },
    );
}

fn persistAgentDescription(application: *Application, finished: DescriptionFinishedType) void {
    _ = application.history_service.setSessionTitle(application.io, .{
        .id = finished.session_id,
        .title = finished.titleSlice(),
        .source = finished.source,
        .state = finished.state,
    });

    if (finished.state == .ready) {
        application.noteSessionChange();
    }
}

fn rearmAgentMaintenance(application: *Application) !void {
    var sources = SourcesType.init(application.io, application.select);
    try sources.waitForAgentMaintenance();
}

fn rearmProxyObservation(application: *Application) !void {
    var sources = SourcesType.init(application.io, application.select);
    try sources.receiveProxyObservation(application.proxy_runtime);
}

fn rearmProxyCapture(application: *Application) !void {
    var sources = SourcesType.init(application.io, application.select);
    try sources.receiveProxyCapture(application.proxy_runtime);
}

fn rearmPluginEffects(application: *Application) !void {
    var sources = SourcesType.init(application.io, application.select);
    try sources.receivePluginEffects(application.plugin_service);
}

const ScheduleResult = enum { no_work, started, failed };

fn startNextDescription(application: *Application) ScheduleResult {
    const command = descriptionCommand(application) orelse return .no_work;
    if (application.agent_description_state.isPending()) {
        return .no_work;
    }

    var job = application.model.agents.nextDescriptionJob() orelse return .no_work;
    defer std.crypto.secureZero(u8, &job.query);

    startAgentDescription(application, command, job) catch {
        _ = commitDescription(application, .{
            .pane = job.pane,
            .session_id = job.session_id,
            .status = .failed,
        });
        return .failed;
    };

    application.agent_description_state.begin();
    return .started;
}

fn commitDescription(application: *Application, result: AgentResult) bool {
    const finished = application.model.agents.finishDescription(&result) orelse return false;
    persistAgentDescription(application, finished);
    return true;
}

fn maintainAgents(application: *Application, result: anyerror!void) !void {
    result catch return;
    try rearmAgentMaintenance(application);

    _ = application.model.agents.expire((std.Io.Timestamp.now(application.io, .real).toMilliseconds()));
    application.pumpAll();
}

fn recordPluginCommand(application: *Application, result: *const ResultType, record: RecordCommandType) void {
    const pane = application.model.panes.resolve(.{ .id = result.pane, .generation = result.pane_generation }) orelse return;
    if (pane.exit != null) {
        return;
    }

    const duration = std.math.cast(i64, record.duration_ms) orelse std.math.maxInt(i64);
    _ = pane.recordAgentCommand(.{
        .command = .{
            .bytes = record.command,
            .cwd = record.cwd,
            .started_at_ms = record.started_at_ms,
            .duration_ns = duration *| std.time.ns_per_ms,
            .exit_code = record.exit_code,
            .status = .completed,
            .truncated = false,
        },
        .provider = record.provider,
        .tool_call_id = record.tool_call_id,
        .origin = .plugin,
        .redact = record.redact,
    });
}

fn applyPluginEvidence(application: *Application, evidence: AgentEvidenceType) bool {
    const pane = application.model.panes.find(evidence.pane) orelse return false;
    if (pane.exit != null) {
        return false;
    }
    const status: core.Status = switch (evidence.state) {
        .working, .settling => .working,
        .blocked => .blocked,
        .ready => .ready,
        .exited => return false,
    };

    return application.model.agents.observeScreen(.{
        .identity = agent_identity.fromPane(pane),
        .signal = .{
            .status = status,
            .confidence = switch (evidence.confidence) {
                .low => 40,
                .medium => 70,
            },
            .identity_confirmed = true,
            .ready_confirmed = status == .ready,
        },
        .observed_at_ms = (std.Io.Timestamp.now(application.io, .real).toMilliseconds()),
    });
}

fn publishPluginEffectNotification(application: *Application, notification: PluginNotification) bool {
    var validation_buffer: [512]u8 = undefined;
    const value: core.Notification = .{
        .level = notification.level,
        .duration_ms = notification.duration_ms,
        .title = notification.title,
        .message = notification.message,
    };
    _ = core.encodeNotification(&validation_buffer, value) catch return false;
    return (application.publishNotification(value)) != 0;
}

fn descriptionCommand(application: *Application) ?CommandType {
    const options = application.agent_description_options orelse return null;
    return .{ .arguments = options.arguments, .timeout_ms = options.timeout_ms };
}
