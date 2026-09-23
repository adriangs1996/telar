//! Runtime agents operations, reached from requests.dispatch.

const agent_thread = @import("../commands/agent_thread.zig");
const RuntimeModel = @import("../../RuntimeModel.zig");
const agent_history = @import("../agent_history.zig");
const core = @import("telar-core");
const Operation = @import("../commands/AgentThreadOperation.zig");
const AcknowledgeAgent = @import("../commands/AcknowledgeAgent.zig");
const tracker_support = @import("../../../agent/tracker_support.zig");
const PaneKeyType = @import("../../../pane/PaneKey.zig");
const ReportAgentSession = @import("../commands/ReportAgentSession.zig");
const report_agent_session = @import("../commands/report_agent_session.zig");
const SessionReferenceType = @import("../../../agent/SessionReference.zig");
const agent_identity = @import("../coordinators/agent_identity.zig");
const session_report_reply = @import("../../entrypoints/requests/report_agent_session.zig");
const ReportAgent = @import("../commands/ReportAgent.zig");
const ReportAgentResult = @import("../commands/ReportAgentResult.zig");
const ClockType = @import("../../../history/Clock.zig");
const ReportAgentCommand = @import("../commands/ReportAgentCommand.zig");
const report_agent_command = @import("../commands/report_agent_command.zig");
const ReportAgentTitle = @import("../commands/ReportAgentTitle.zig");
const report_agent_title = @import("../commands/report_agent_title.zig");
const title_report_reply = @import("../../entrypoints/requests/report_agent_title.zig");
const suggestion = @import("../suggestion.zig");
const types = @import("../../../engine/types.zig");
const PromptType = @import("../../../engine/Prompt.zig");
const ResponseQueueType = @import("../../delivery/ResponseQueue.zig");
const std = @import("std");
const sound_module = @import("../../../agent/sound.zig");
const RequestContext = @import("../RequestContext.zig");

/// Example: `try agents.routeSuggestCommand(request, command);`.
pub fn routeSuggestCommand(request: *RequestContext, command: core.SuggestCommand) !void {
    const model = request.model;
    const session = request.session;
    const service = model.resources.engineService() orelse {
        return queueSuggestionStatus(&session.delivery.responses, command.request_id, .unavailable);
    };
    const pane = model.panes.resolveControl(.{ .id = command.pane_id, .generation = 0 }) orelse {
        return queueSuggestionStatus(&session.delivery.responses, command.request_id, .failed);
    };

    var screen_storage: [core.max_pane_text_bytes]u8 = undefined;
    const dump = pane.dumpText(.{ .rows = suggestion.context_rows, .source = .screen }, &screen_storage);
    var prompt_buffer: [types.max_prompt_bytes]u8 = undefined;
    const prompt = suggestion.buildPrompt(.{
        .cwd = pane.cwd.slice(),
        .screen = screen_storage[0..dump.len],
        .request = command.text,
    }, &prompt_buffer);
    const purpose: types.Purpose = .{ .suggestion = .{
        .client_id = session.key.id,
        .client_generation = session.key.generation,
        .request_id = core.raw(command.request_id),
    } };
    const queued = PromptType.init(purpose, prompt) catch null;
    if (queued == null or !service.submit(model.io, .{ .prompt = queued.? })) {
        return queueSuggestionStatus(&session.delivery.responses, command.request_id, .failed);
    }
}

fn queueSuggestionStatus(responses: *ResponseQueueType, request_id: core.RequestId, status: core.SuggestionStatus) !void {
    try responses.push(.{ .command_suggestion = .{ .request_id = request_id, .status = status } });
}

/// Example: `try agents.control(request, wire);`.
pub fn control(request: *RequestContext, wire: anytype) !void {
    const T = @TypeOf(wire);
    const action: agent_thread.Action = if (T == core.AgentPrompt)
        .{ .prompt = .{ .text = wire.text, .options = wire.options, .images = wire.images } }
    else if (T == core.AgentInterrupt)
        .interrupt
    else if (T == core.AgentResume)
        .{ .resume_conversation = .{ .index = wire.conversation_index, .revision = wire.expected_revision } }
    else if (T == core.AgentApproval)
        .{ .approval = .{ .id = wire.approval_id, .accepted = wire.accept } }
    else if (T == core.QueryAgentThread)
        .query
    else
        @compileError("unsupported agent control");
    const key = agentControl(request, .{
        .pane = .{ .id = wire.pane_id, .generation = wire.pane_generation },
        .action = action,
    }) catch |err| {
        try request.session.delivery.responses.push(.{ .request_failed = .{
            .request_id = wire.request_id,
            .code = switch (err) {
                error.PaneNotFound => .pane_not_found,
                error.NotAnAgentPane => .invalid_request,
                error.PaneExited => .pane_exited,
                error.AgentBusy, error.ConversationAlreadyOpen => .agent_blocked,
                error.InvalidConversation => .invalid_request,
                error.InvalidAgentOptions => .invalid_request,
            },
            .message = switch (err) {
                error.PaneNotFound => "agent pane no longer exists",
                error.NotAnAgentPane => "pane is a terminal",
                error.PaneExited => "agent pane is closing",
                error.AgentBusy => "agent is busy or waiting for a decision",
                error.ConversationAlreadyOpen => "conversation is already open in another pane",
                error.InvalidConversation => "choose a recent conversation from an unused agent pane",
                error.InvalidAgentOptions => "model or reasoning effort is not available for this agent",
            },
        } });
        return;
    };
    if (action == .query) {
        request.session.delivery.requestAgentThread(key);
    }
    try request.session.delivery.responses.push(.{ .request_completed = .{ .request_id = wire.request_id } });
}

/// Example: `try agents.routeQueryAgentHistory(request, message);`.
pub fn routeQueryAgentHistory(request: *RequestContext, message: core.QueryAgentHistory) !void {
    try agent_history.request(request.model, request.session, message);
}

/// Example: `try agents.routeAcknowledgeAgent(request, acknowledgement);`.
pub fn routeAcknowledgeAgent(request: *RequestContext, acknowledgement: core.AcknowledgeAgent) !void {
    const now_ms = std.Io.Timestamp.now(request.model.io, .real).toMilliseconds();

    receiveAcknowledgeAgent(request, acknowledgement, now_ms);
}

/// Example: `try agents.routeQueryAgents(request, query);`.
pub fn routeQueryAgents(request: *RequestContext, query: core.QueryAgents) !void {
    _ = query;
    request.session.delivery.requestAgentSnapshot();
}

/// Example: `try agents.routeReportAgentSession(request, report);`.
pub fn routeReportAgentSession(request: *RequestContext, report: core.ReportAgentSession) !void {
    const model = request.model;
    const now_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds();

    if (try receiveReportAgentSession(request, report, now_ms) == .recorded) {
        model.noteSessionChange();
    }
}

/// Example: `try agents.routeReportAgent(request, report);`.
pub fn routeReportAgent(request: *RequestContext, report: core.ReportAgent) !void {
    const model = request.model;
    const now_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds();

    const result = try receiveReportAgent(request, report, .{
        .real_ms = now_ms,
        .awake_ns = @intCast(std.Io.Timestamp.now(model.io, .awake).toNanoseconds()),
    });
    if (result.session_recorded) {
        model.noteSessionChange();
    }
    if (result.outcome != .applied) {
        return;
    }

    const sound = sound_module.soundForTransition(result.previous, result.current) orelse return;
    model.publishAgentSound(.{
        .pane_id = report.pane_id,
        .pane_generation = report.pane_generation,
        .sound = sound,
    });
}

/// Example: `try agents.routeReportAgentCommand(request, report);`.
pub fn routeReportAgentCommand(request: *RequestContext, report: core.ReportAgentCommand) !void {
    const model = request.model;
    const now_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds();

    try receiveReportAgentCommand(request, report, now_ms);
}

/// Example: `try agents.routeReportAgentTitle(request, report);`.
pub fn routeReportAgentTitle(request: *RequestContext, report: core.ReportAgentTitle) !void {
    const model = request.model;

    if (try receiveReportAgentTitle(request, report) == .recorded) {
        model.noteSessionChange();
    }
}

fn acknowledgeAgent(request: *RequestContext, command: AcknowledgeAgent) tracker_support.AcknowledgeResult {
    const key: PaneKeyType = .{
        .id = command.pane_id,
        .generation = command.pane_generation,
    };

    return request.model.agents.acknowledge(key, command.now_ms);
}

fn receiveAcknowledgeAgent(request: *RequestContext, acknowledgement: core.AcknowledgeAgent, now_ms: i64) void {
    const result = acknowledgeAgent(request, .{
        .pane_id = acknowledgement.pane_id,
        .pane_generation = acknowledgement.pane_generation,
        .now_ms = now_ms,
    });

    if (result == .unknown_agent) {
        request.model.metrics.stale_client_messages += 1;
    }
}

fn reportAgentSession(request: *RequestContext, command: ReportAgentSession) report_agent_session.ReportAgentSessionResult {
    const model = request.model;

    const pane = model.panes.resolveConst(command.pane) orelse return .pane_not_found;
    if (pane.exit != null) {
        return .pane_not_found;
    }
    const reference = SessionReferenceType.init(command.session, command.now_ms) catch return .invalid_session;
    const identity = agent_identity.fromPane(pane);

    return if (model.agents.observeSessionReference(identity, reference)) .recorded else .unchanged;
}

fn receiveReportAgentSession(request: *RequestContext, wire: core.ReportAgentSession, now_ms: i64) !session_report_reply.Outcome {
    const result = reportAgentSession(request, .{
        .pane = .{ .id = wire.pane_id, .generation = wire.pane_generation },
        .session = wire.session,
        .now_ms = now_ms,
    });

    switch (result) {
        .recorded, .unchanged => {
            try request.session.delivery.responses.push(.{ .request_completed = .{ .request_id = wire.request_id } });
            return if (result == .recorded) .recorded else .unchanged;
        },
        .pane_not_found => {
            try request.session.delivery.responses.push(.{ .request_failed = .{
                .request_id = wire.request_id,
                .code = .pane_not_found,
                .message = "pane not found",
            } });
            return .rejected;
        },
        .invalid_session => {
            try request.session.delivery.responses.push(.{ .request_failed = .{
                .request_id = wire.request_id,
                .code = .invalid_request,
                .message = "invalid session reference",
            } });
            return .rejected;
        },
    }
}

fn reportAgent(request: *RequestContext, command: ReportAgent) ReportAgentResult {
    const model = request.model;

    const pane = model.panes.resolveConst(command.pane) orelse return .{ .outcome = .pane_not_found };
    if (pane.exit != null) {
        return .{ .outcome = .pane_not_found };
    }
    const session: ?SessionReferenceType = if (command.session.len == 0)
        null
    else
        SessionReferenceType.init(command.session, command.now_ms) catch return .{ .outcome = .invalid_session };
    const identity = agent_identity.fromPane(pane);
    const previous = model.agents.projectedStatus(identity.key);
    const previous_session = model.agents.sessionReference(identity.key);

    const changed = model.agents.observeReport(.{
        .identity = identity,
        .state = command.state,
        .blocked_reason = command.blocked_reason,
        .event = command.event,
        .observed_at_ms = command.now_ms,
        .observed_at_ns = command.now_ns,
        .session = session,
        .session_file = command.session_file,
    });
    const current = model.agents.projectedStatus(identity.key);
    const current_session = model.agents.sessionReference(identity.key);

    return .{
        .outcome = if (changed) .applied else .unchanged,
        .previous = previous,
        .current = current,
        .session_recorded = if (current_session) |recorded|
            if (previous_session) |previous_reference| !std.mem.eql(u8, recorded.slice(), previous_reference.slice()) else true
        else
            false,
    };
}

fn receiveReportAgent(request: *RequestContext, wire: core.ReportAgent, clock: ClockType) !ReportAgentResult {
    const result = reportAgent(request, .{
        .pane = .{ .id = wire.pane_id, .generation = wire.pane_generation },
        .state = wire.state,
        .blocked_reason = wire.blocked_reason,
        .event = wire.event,
        .session = wire.session,
        .session_file = .{ .kind = wire.session_file_kind, .path = wire.session_file },
        .now_ms = clock.real_ms,
        .now_ns = clock.awake_ns,
    });

    switch (result.outcome) {
        .applied, .unchanged => try request.session.delivery.responses.push(.{ .request_completed = .{ .request_id = wire.request_id } }),
        .pane_not_found => try request.session.delivery.responses.push(.{ .request_failed = .{
            .request_id = wire.request_id,
            .code = .pane_not_found,
            .message = "pane not found",
        } }),
        .invalid_session => try request.session.delivery.responses.push(.{ .request_failed = .{
            .request_id = wire.request_id,
            .code = .invalid_request,
            .message = "invalid session reference",
        } }),
    }

    return result;
}

fn reportAgentCommand(request: *RequestContext, report: ReportAgentCommand) report_agent_command.Outcome {
    const model = request.model;

    const pane = model.panes.resolve(report.pane) orelse return .pane_not_found;
    if (pane.exit != null) {
        return .pane_not_found;
    }

    const queued = pane.recordAgentCommand(.{
        .command = .{
            .bytes = report.command,
            .cwd = report.cwd,
            .started_at_ms = report.now_ms,
            .duration_ns = 0,
            .exit_code = report.exit_code,
            .status = .completed,
            .truncated = false,
        },
        .provider = report.provider,
        .tool_call_id = report.tool_call_id,
        .origin = .hook,
        .phase = report.phase,
    });
    return if (queued) .applied else .queue_full;
}

fn receiveReportAgentCommand(request: *RequestContext, wire: core.ReportAgentCommand, now_ms: i64) !void {
    const outcome = reportAgentCommand(request, .{
        .pane = .{ .id = wire.pane_id, .generation = wire.pane_generation },
        .phase = wire.phase,
        .provider = wire.provider,
        .tool_call_id = wire.tool_call_id,
        .command = wire.command,
        .cwd = wire.cwd,
        .exit_code = wire.exit_code,
        .now_ms = now_ms,
    });

    switch (outcome) {
        .applied => try request.session.delivery.responses.push(.{ .request_completed = .{ .request_id = wire.request_id } }),
        .pane_not_found => try request.session.delivery.responses.push(.{ .request_failed = .{
            .request_id = wire.request_id,
            .code = .pane_not_found,
            .message = "pane not found",
        } }),
        .queue_full => try request.session.delivery.responses.push(.{ .request_failed = .{
            .request_id = wire.request_id,
            .code = .resource_limit,
            .message = "history queue full",
        } }),
    }
}

/// Example: `agents.reportAgentTitle(model, command);`.
pub fn reportAgentTitle(model: *RuntimeModel, command: ReportAgentTitle) report_agent_title.ReportAgentTitleResult {
    const pane = model.panes.resolveConst(command.pane) orelse return .pane_not_found;
    if (pane.exit != null) {
        return .pane_not_found;
    }

    const identity = agent_identity.fromPane(pane);
    const changed = model.agents.reportTitle(identity, command.title) catch return .invalid_title;

    return if (changed) .recorded else .unchanged;
}

fn receiveReportAgentTitle(request: *RequestContext, wire: core.ReportAgentTitle) !title_report_reply.Outcome {
    const result = reportAgentTitle(request.model, .{
        .pane = .{ .id = wire.pane_id, .generation = wire.pane_generation },
        .title = wire.title,
    });

    switch (result) {
        .recorded, .unchanged => {
            try request.session.delivery.responses.push(.{ .request_completed = .{ .request_id = wire.request_id } });
            return if (result == .recorded) .recorded else .unchanged;
        },
        .pane_not_found => {
            try request.session.delivery.responses.push(.{ .request_failed = .{
                .request_id = wire.request_id,
                .code = .pane_not_found,
                .message = "pane not found",
            } });
            return .rejected;
        },
        .invalid_title => {
            try request.session.delivery.responses.push(.{ .request_failed = .{
                .request_id = wire.request_id,
                .code = .invalid_request,
                .message = "invalid session title",
            } });
            return .rejected;
        },
    }
}

fn agentControl(request: *RequestContext, operation: Operation) !PaneKeyType {
    const pane = request.model.panes.resolve(operation.pane) orelse return error.PaneNotFound;
    if (pane.kind != .agent) {
        return error.NotAnAgentPane;
    }
    if (pane.close_requested or pane.exit != null) {
        return error.PaneExited;
    }
    if (operation.action == .prompt) {
        const snapshot = pane.agent_thread orelse return error.InvalidAgentOptions;
        if (!snapshot.accepts(operation.action.prompt.options)) {
            return error.InvalidAgentOptions;
        }
    }
    const session = pane.session.agent.session;
    const accepted = switch (operation.action) {
        .prompt => |text| session.submit(request.model.io, text),
        .interrupt => session.interrupt(request.model.io),
        .approval => |decision| session.approve(request.model.io, decision),
        .query => true,
        .resume_conversation => |selection| blk: {
            const snapshot = pane.agent_thread orelse return error.InvalidConversation;
            if (snapshot.revision != selection.revision or !snapshot.canResume() or snapshot.recent.phase != .ready or selection.index >= snapshot.recent.count) {
                return error.InvalidConversation;
            }

            const entry = snapshot.recent.entries[selection.index];
            for (request.model.panes.items) |slot| {
                const other = slot orelse continue;
                if (other == pane or other.kind != .agent or other.exit != null) {
                    continue;
                }

                if (try other.session.agent.session.claims(request.model.io, entry.idSlice())) {
                    return error.ConversationAlreadyOpen;
                }
            }

            break :blk session.resumeConversation(request.model.io, entry);
        },
    };
    if (!accepted) {
        return error.AgentBusy;
    }

    if (operation.action == .prompt and core.AgentCommand.parse(operation.action.prompt.text) == null) {
        if (if (request.model.agent_description_options != null) &request.model.agents else null) |tracker| {
            _ = tracker.observeSubmittedPrompt(agent_identity.fromPane(pane), operation.action.prompt.text);
        }
    }
    return pane.key();
}
