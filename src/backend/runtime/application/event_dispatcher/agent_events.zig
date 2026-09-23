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

const RuntimeModel = @import("../../RuntimeModel.zig");

/// Applies one proxy observation to its agent and rearms proxy receive.
///
/// ```zig
/// try AgentEvents.handleProxyObservation(&model, result);
/// ```
pub fn handleProxyObservation(model: *RuntimeModel, result: anyerror!ObservationType) !void {
    const event = result catch return;
    try rearmProxyObservation(model);

    const pane = model.panes.resolve(event.pane) orelse {
        model.metrics.stale_pane_events += 1;
        return;
    };

    if (comptime core.enabled) {
        model.metrics.proxy_observations +|= 1;
    }

    const observation = proxy_observation.translate(event, pane) orelse return;
    _ = model.agents.observeProxy(observation);
    scheduleDescription(model);
}

pub fn handleProxyCapture(model: *RuntimeModel, result: anyerror!*Half) !void {
    const half = result catch return;
    errdefer half.deinit();
    try rearmProxyCapture(model);

    const key: PaneKeyType = .{ .id = half.pane.id, .generation = half.pane.generation };
    if (model.panes.resolve(key) == null) {
        half.deinit();
        return;
    }

    model.resources.proxy.decodeCapture(half);
    model.resources.proxy.acceptCapture(.{
        .now_ms = (std.Io.Timestamp.now(model.io, .real).toMilliseconds()),
        .half = half,
    });
}

/// Authorizes and applies one bounded effect batch, then rearms receive.
///
/// ```zig
/// try AgentEvents.handlePluginEffects(&model, result);
/// ```
pub fn handlePluginEffects(model: *RuntimeModel, result_value: anyerror!*ResultType) !void {
    const result = result_value catch return;
    defer result.deinit();
    try rearmPluginEffects(model);
    model.resources.pluginService().authorize(result) catch return;

    for (result.batch.slice()) |effect| switch (effect) {
        .record_command => |record| recordPluginCommand(model, result, record),
        .agent_evidence => |evidence| _ = applyPluginEvidence(model, evidence),
        .notification => |notification| _ = publishPluginEffectNotification(model, notification),
    };
}

/// Applies one maintenance tick, expires stale agent activity and
/// rearms the periodic source.
///
/// ```zig
/// try AgentEvents.handleMaintenance(&model, result);
/// ```
pub fn handleMaintenance(model: *RuntimeModel, result: anyerror!void) !void {
    try maintainAgents(model, result);
    try model.flushSessionCheckpoint();
    model.tickGitStatus();
    model.tickSessionNames();
    checkEngineIdle(model);
    model.resources.proxy.expireCaptures((std.Io.Timestamp.now(model.io, .real).toMilliseconds()));
}

/// Applies one generated description and persists the resulting title.
///
/// ```zig
/// AgentEvents.handleDescription(&model, result);
/// ```
pub fn handleDescription(model: *RuntimeModel, result: AgentResult) void {
    model.agent_description_state.complete();
    _ = commitDescription(model, result);
    _ = startNextDescription(model);
}

/// Starts the next queued agent-description job when the configured
/// generator and coordinator state permit it.
///
/// ```zig
/// AgentEvents.scheduleDescription(&model);
/// ```
pub fn scheduleDescription(model: *RuntimeModel) void {
    _ = startNextDescription(model);
}

/// Applies one engine reply and rearms the engine receive.
///
/// ```zig
/// try AgentEvents.handleEngineResponse(&model, result);
/// ```
pub fn handleEngineResponse(model: *RuntimeModel, result: anyerror!ResponseType) !void {
    const response = result catch return;
    const service = model.resources.engineService() orelse return;
    var sources = SourcesType.init(model.io, model.select);
    try sources.receiveEngine(service);

    switch (response.purpose) {
        .suggestion => |target| deliverSuggestion(model, target, &response),
    }
}

/// Answers the client that asked for a suggestion, if it is still
/// connected; a departed client simply drops the reply.
fn deliverSuggestion(model: *RuntimeModel, target: types.Purpose.Suggestion, response: *const ResponseType) void {
    const session = model.clients.resolve(.{ .id = target.client_id, .generation = target.client_generation }) orelse return;
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
}

/// Asks the engine to kill its child when it has been idle. Called
/// from the agent maintenance tick; it queues nothing when no child
/// is alive.
///
/// ```zig
/// AgentEvents.checkEngineIdle(&model);
/// ```
pub fn checkEngineIdle(model: *RuntimeModel) void {
    const service = model.resources.engineService() orelse return;
    service.requestIdleCheck(model.io);
}

fn startAgentDescription(model: *RuntimeModel, command: CommandType, job_value: JobType) !void {
    var job = job_value;
    defer std.crypto.secureZero(u8, &job.query);

    try model.select.concurrent(
        .agent_description,
        description_module.generate,
        .{ model.io, model.gpa, .{ .command = command, .job = job } },
    );
}

fn persistAgentDescription(model: *RuntimeModel, finished: DescriptionFinishedType) void {
    _ = model.resources.history.service().setSessionTitle(model.io, .{
        .id = finished.session_id,
        .title = finished.titleSlice(),
        .source = finished.source,
        .state = finished.state,
    });

    if (finished.state == .ready) {
        model.noteSessionChange();
    }
}

fn rearmAgentMaintenance(model: *RuntimeModel) !void {
    var sources = SourcesType.init(model.io, model.select);
    try sources.waitForAgentMaintenance();
}

fn rearmProxyObservation(model: *RuntimeModel) !void {
    var sources = SourcesType.init(model.io, model.select);
    try sources.receiveProxyObservation(&model.resources.proxy);
}

fn rearmProxyCapture(model: *RuntimeModel) !void {
    var sources = SourcesType.init(model.io, model.select);
    try sources.receiveProxyCapture(&model.resources.proxy);
}

fn rearmPluginEffects(model: *RuntimeModel) !void {
    var sources = SourcesType.init(model.io, model.select);
    try sources.receivePluginEffects(model.resources.pluginService());
}

const ScheduleResult = enum { no_work, started, failed };

fn startNextDescription(model: *RuntimeModel) ScheduleResult {
    const command = descriptionCommand(model) orelse return .no_work;
    if (model.agent_description_state.isPending()) {
        return .no_work;
    }

    var job = model.agents.nextDescriptionJob() orelse return .no_work;
    defer std.crypto.secureZero(u8, &job.query);

    startAgentDescription(model, command, job) catch {
        _ = commitDescription(model, .{
            .pane = job.pane,
            .session_id = job.session_id,
            .status = .failed,
        });
        return .failed;
    };

    model.agent_description_state.begin();
    return .started;
}

fn commitDescription(model: *RuntimeModel, result: AgentResult) bool {
    const finished = model.agents.finishDescription(&result) orelse return false;
    persistAgentDescription(model, finished);
    return true;
}

fn maintainAgents(model: *RuntimeModel, result: anyerror!void) !void {
    result catch return;
    try rearmAgentMaintenance(model);

    _ = model.agents.expire((std.Io.Timestamp.now(model.io, .real).toMilliseconds()));
}

fn recordPluginCommand(model: *RuntimeModel, result: *const ResultType, record: RecordCommandType) void {
    const pane = model.panes.resolve(.{ .id = result.pane, .generation = result.pane_generation }) orelse return;
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

fn applyPluginEvidence(model: *RuntimeModel, evidence: AgentEvidenceType) bool {
    const pane = model.panes.find(evidence.pane) orelse return false;
    if (pane.exit != null) {
        return false;
    }
    const status: core.Status = switch (evidence.state) {
        .working, .settling => .working,
        .blocked => .blocked,
        .ready => .ready,
        .exited => return false,
    };

    return model.agents.observeScreen(.{
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
        .observed_at_ms = (std.Io.Timestamp.now(model.io, .real).toMilliseconds()),
    });
}

fn publishPluginEffectNotification(model: *RuntimeModel, notification: PluginNotification) bool {
    var validation_buffer: [512]u8 = undefined;
    const value: core.Notification = .{
        .level = notification.level,
        .duration_ms = notification.duration_ms,
        .title = notification.title,
        .message = notification.message,
    };
    _ = core.encodeNotification(&validation_buffer, value) catch return false;
    return (model.publishNotification(value)) != 0;
}

fn descriptionCommand(model: *RuntimeModel) ?CommandType {
    const options = model.agent_description_options orelse return null;
    return .{ .arguments = options.arguments, .timeout_ms = options.timeout_ms };
}
