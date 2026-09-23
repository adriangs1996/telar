//! A client drives a managed agent pane through its structured interface:
//! prompts, interrupts, approvals, resumed conversations and queries.

const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const PaneKey = @import("../pane/PaneKey.zig");
const agent_identity = @import("application/coordinators/agent_identity.zig");
const client_request = @import("client_request.zig");

const Action = union(enum) {
    prompt: core.AgentSubmission,
    interrupt,
    resume_conversation: struct { index: u8, revision: u64 },
    approval: core.AgentApprovalDecision,
    query,
};

/// Sends one structured command to an agent pane and replies once.
///
/// ```zig
/// try agent_control.send(model, session, request);
/// ```
pub fn send(model: *RuntimeModel, session: *Session, request: anytype) !void {
    const T = @TypeOf(request);
    const action: Action = if (T == core.AgentPrompt)
        .{ .prompt = .{ .text = request.text, .options = request.options, .images = request.images } }
    else if (T == core.AgentInterrupt)
        .interrupt
    else if (T == core.AgentResume)
        .{ .resume_conversation = .{ .index = request.conversation_index, .revision = request.expected_revision } }
    else if (T == core.AgentApproval)
        .{ .approval = .{ .id = request.approval_id, .accepted = request.accept } }
    else if (T == core.QueryAgentThread)
        .query
    else
        @compileError("unsupported agent control");

    const key = command(model, .{ .id = request.pane_id, .generation = request.pane_generation }, action) catch |err| {
        return switch (err) {
            error.PaneNotFound => client_request.fail(session, request.request_id, .pane_not_found, "agent pane no longer exists"),
            error.NotAnAgentPane => client_request.fail(session, request.request_id, .invalid_request, "pane is a terminal"),
            error.PaneExited => client_request.fail(session, request.request_id, .pane_exited, "agent pane is closing"),
            error.AgentBusy => client_request.fail(session, request.request_id, .agent_blocked, "agent is busy or waiting for a decision"),
            error.ConversationAlreadyOpen => client_request.fail(session, request.request_id, .agent_blocked, "conversation is already open in another pane"),
            error.InvalidConversation => client_request.fail(session, request.request_id, .invalid_request, "choose a recent conversation from an unused agent pane"),
            error.InvalidAgentOptions => client_request.fail(session, request.request_id, .invalid_request, "model or reasoning effort is not available for this agent"),
        };
    };

    if (action == .query) {
        session.delivery.requestAgentThread(key);
    }

    try client_request.complete(session, request.request_id);
}

fn command(model: *RuntimeModel, key: PaneKey, action: Action) !PaneKey {
    const pane = model.panes.resolve(key) orelse return error.PaneNotFound;
    if (pane.kind != .agent) {
        return error.NotAnAgentPane;
    }

    if (pane.close_requested or pane.exit != null) {
        return error.PaneExited;
    }

    if (action == .prompt) {
        const snapshot = pane.agent_thread orelse return error.InvalidAgentOptions;
        if (!snapshot.accepts(action.prompt.options)) {
            return error.InvalidAgentOptions;
        }
    }

    const session = pane.session.agent.session;
    const accepted = switch (action) {
        .prompt => |submission| session.submit(model.io, submission),
        .interrupt => session.interrupt(model.io),
        .approval => |decision| session.approve(model.io, decision),
        .query => true,
        .resume_conversation => |selection| accepted: {
            const snapshot = pane.agent_thread orelse return error.InvalidConversation;
            if (snapshot.revision != selection.revision or !snapshot.canResume() or snapshot.recent.phase != .ready or selection.index >= snapshot.recent.count) {
                return error.InvalidConversation;
            }

            const entry = snapshot.recent.entries[selection.index];
            for (model.panes.items) |slot| {
                const other = slot orelse continue;
                if (other == pane or other.kind != .agent or other.exit != null) {
                    continue;
                }

                if (try other.session.agent.session.claims(model.io, entry.idSlice())) {
                    return error.ConversationAlreadyOpen;
                }
            }

            break :accepted session.resumeConversation(model.io, entry);
        },
    };

    if (!accepted) {
        return error.AgentBusy;
    }

    if (action == .prompt and core.AgentCommand.parse(action.prompt.text) == null and model.agent_description_options != null) {
        _ = model.agents.observeSubmittedPrompt(agent_identity.fromPane(pane), action.prompt.text);
    }

    return pane.key();
}
