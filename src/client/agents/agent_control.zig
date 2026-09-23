//! Agent control: sends prompts, images, interrupts, resumes and approvals to
//! an agent and finishes their requests.
const data = @import("model");
const core = @import("telar-core");
const runtime_io = @import("../connection/runtime_io.zig");
const notifications = @import("../notifications/notifications.zig");
const tab_creation = @import("../workspace/tab_creation.zig");
const Client = @import("../execution/Client.zig");

/// Maps attachment limits to a visible failure without changing the existing draft.
/// Example: `try agent_control.attachAgentImage(app, pane_id, path);`
pub fn attachAgentImage(client: *Client, pane_id: core.PaneId, path: []const u8) !void {
    _ = client.model.attachAgentImage(pane_id, path) catch |err| {
        try notifications.publishNotificationNow(
            client,
            .{
                .level = .warning,
                .title = "Image was not attached",
                .message = switch (err) {
                    error.TooManyAgentImages => "A message can contain up to four images.",
                    error.InvalidAgentImage => "The clipboard returned an invalid image.",
                    else => "There is not enough memory to retain the image attachment.",
                },
            },
        );
        return;
    };
}

/// Copies and correlates a prompt, preserving the draft until acknowledgement.
/// Example: `try agent_control.submitAgentPrompt(app, pane_id);`
pub fn submitAgentPrompt(model: *data.ClientModel, pane_id: core.PaneId) !void {
    if (model.request_lifecycle.tracker.hasPane(.agent_prompt, pane_id)) {
        return;
    }

    const intent = model.planAgentPrompt(pane_id) orelse return;
    const request_id = try model.request_lifecycle.nextId();
    try sendAgentPromptRequest(
        model,
        .{
            .request_id = request_id,
            .pane_id = pane_id,
            .pane_generation = intent.pane_generation,
            .text = intent.text,
            .images = intent.images,
            .options = intent.options,
        },
        .{
            .pane_id = pane_id,
            .pane_generation = intent.pane_generation,
            .attachment_generation = intent.attachment_generation,
            .location = intent.location,
            .composer_content_revision = intent.composer_content_revision,
        },
    );
}

/// Example: `try agent_control.interruptAgent(app, pane_id);`
pub fn interruptAgent(model: *data.ClientModel, pane_id: core.PaneId) !void {
    const pending = agentOperation(model, pane_id) orelse return;
    if (model.request_lifecycle.tracker.hasPane(.agent_control, pane_id)) {
        return;
    }

    const request_id = try model.request_lifecycle.nextId();
    try runtime_io.sendRuntimeRequest(
        model,
        .{
            .registration = .{
                .request_id = request_id,
                .continuation = .{
                    .agent_control = pending,
                },
            },
            .message = .{
                .agent_interrupt = .{
                    .request_id = request_id,
                    .pane_id = pane_id,
                    .pane_generation = pending.pane_generation,
                },
            },
        },
    );
}

/// Resumes an advertised conversation without consuming the composer's draft.
/// Example: `try agent_control.resumeAgentConversation(app, pane_id, index);`
pub fn resumeAgentConversation(model: *data.ClientModel, pane_id: core.PaneId, index: u8) !void {
    const pending = agentOperation(model, pane_id) orelse return;
    const pane = model.agentPane(pane_id) orelse return;
    const snapshot = pane.agent_thread orelse return;
    if (!snapshot.canResume() or index >= snapshot.recent.count or model.request_lifecycle.tracker.hasPane(.agent_control, pane_id) or model.request_lifecycle.tracker.hasPane(.agent_prompt, pane_id)) {
        return;
    }

    const request_id = try model.request_lifecycle.nextId();
    try runtime_io.sendRuntimeRequest(
        model,
        .{
            .registration = .{
                .request_id = request_id,
                .continuation = .{
                    .agent_control = pending,
                },
            },
            .message = .{
                .agent_resume = .{
                    .request_id = request_id,
                    .pane_id = pane_id,
                    .pane_generation = pending.pane_generation,
                    .expected_revision = snapshot.revision,
                    .conversation_index = index,
                },
            },
        },
    );
}

/// Example: `try agent_control.approveAgent(app, decision);`
pub fn approveAgent(model: *data.ClientModel, decision: data.AgentDecision) !void {
    const pending = agentOperation(model, decision.pane_id) orelse return;
    const pane = model.agentPane(decision.pane_id) orelse return;
    const thread = pane.agent_thread orelse return;
    const approval = thread.pending_approval orelse return;
    if (approval.id != decision.approval_id or model.request_lifecycle.tracker.hasPane(.agent_control, decision.pane_id)) {
        return;
    }

    const request_id = try model.request_lifecycle.nextId();
    try runtime_io.sendRuntimeRequest(
        model,
        .{
            .registration = .{
                .request_id = request_id,
                .continuation = .{
                    .agent_control = pending,
                },
            },
            .message = .{
                .agent_approval = .{
                    .request_id = request_id,
                    .pane_id = decision.pane_id,
                    .pane_generation = pending.pane_generation,
                    .approval_id = decision.approval_id,
                    .accept = decision.accept,
                },
            },
        },
    );
}

/// Registers correlation before copying the request; failed delivery removes only that registration.
/// Example: `try agent_control.sendAgentPromptRequest(client, request, operation);`
pub fn sendAgentPromptRequest(model: *data.ClientModel, request: core.AgentPrompt, operation: data.AgentOperation) !void {
    try model.request_lifecycle.tracker.add(
        request.request_id,
        .{
            .agent_prompt = operation,
        },
    );
    errdefer _ = model.request_lifecycle.tracker.take(request.request_id);
    try model.to_runtime.pushAgentPrompt(request);
}

pub fn createAgentTab(client: *Client) !void {
    if (!client.model.host.host_capabilities.agent_panes) {
        try notifications.publishNotificationNow(
            client,
            .{
                .level = .info,
                .title = "Agent panes require the GUI",
                .message = "Open Telar GUI to create an agent tab.",
            },
        );
        return;
    }

    _ = try tab_creation.requestTabCreation(
        client,
        .{
            .kind = .agent,
            .label = "Codex",
        },
    );
}

pub fn queryAgentThread(model: *data.ClientModel, pane_id: core.PaneId) !void {
    const pending = agentOperation(model, pane_id) orelse return;
    if (model.request_lifecycle.tracker.hasPane(.agent_query, pane_id)) {
        return;
    }

    const request_id = try model.request_lifecycle.nextId();
    try runtime_io.sendRuntimeRequest(
        model,
        .{
            .registration = .{
                .request_id = request_id,
                .continuation = .{
                    .agent_query = pending,
                },
            },
            .message = .{
                .query_agent_thread = .{
                    .request_id = request_id,
                    .pane_id = pane_id,
                    .pane_generation = pending.pane_generation,
                },
            },
        },
    );
}

pub fn completeAgentRequest(model: *data.ClientModel, reply: core.RequestCompleted) !void {
    const continuation = model.request_lifecycle.tracker.take(reply.request_id) orelse return error.UnexpectedControlReply;
    switch (continuation) {
        .agent_prompt => |pending| {
            _ = model.completeAgentPrompt(pending);
        },
        .agent_control, .agent_query, .ignored => {},
        else => return error.UnexpectedControlReply,
    }
}

fn agentOperation(model: *const data.ClientModel, pane_id: core.PaneId) ?data.AgentOperation {
    const pane = model.agentPane(pane_id) orelse return null;
    return .{
        .pane_id = pane_id,
        .pane_generation = pane.pane_generation,
        .attachment_generation = pane.attachment_generation,
        .location = pane.location,
    };
}
