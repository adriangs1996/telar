const core = @import("telar-core");
const Client = @import("../../AttachedClient.zig");
const Pane = @import("../../panes/Pane.zig");
const AgentOperation = @import("../../connection/AgentOperation.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const tab_creations = @import("../tabs/tab_creations.zig");
const notifications = @import("../notifications/notifications.zig");
const Command = @import("../../model/name_prompt.zig").Command;

pub const AgentDecision = @import("../../application/agents/AgentDecision.zig");

/// Creates a Codex pane in a new tab in the active workspace. Example: `try agent_threads.create(client);`
pub fn create(client: *Client) !void {
    if (!client.model.hostCapabilities().agent_panes) {
        try notifications.publishNow(client, .{
            .level = .info,
            .title = "Agent panes require the GUI",
            .message = "Open Telar GUI to create an agent tab.",
        });
        return;
    }

    _ = try tab_creations.request(client, .{ .kind = .agent, .label = "Codex" });
}

/// Borrows the current attached composer for native editing. Example: `const editor = agent_threads.field(client, id) orelse return;`
pub fn field(client: *const Client, pane_id: core.PaneId) ?*const Pane.ComposerField {
    const pane = client.model.agentPane(pane_id) orelse return null;
    return &pane.composer_field;
}

/// Delivers semantic editor input without forwarding terminal bytes. Example: `try agent_threads.edit(client, id, .backspace);`
pub fn edit(client: *Client, pane_id: core.PaneId, command: Command) !void {
    _ = client.model.editAgentComposer(pane_id, command);
}

/// Maps attachment limits to a visible failure without changing the existing draft.
/// Example: `try agent_threads.attachImage(client, id, path);`
pub fn attachImage(client: *Client, pane_id: core.PaneId, path: []const u8) !void {
    _ = client.model.attachAgentImage(pane_id, path) catch |err| {
        try notifications.publishNow(client, .{
            .level = .warning,
            .title = "Image was not attached",
            .message = switch (err) {
                error.TooManyAgentImages => "A message can contain up to four images.",
                error.InvalidAgentImage => "The clipboard returned an invalid image.",
                else => "There is not enough memory to retain the image attachment.",
            },
        });
        return;
    };
}

/// Example: `agent_threads.removeImage(client, id, removal);`
pub fn removeImage(client: *Client, pane_id: core.PaneId, removal: Pane.ImageRemoval) void {
    _ = client.model.removeAgentImage(pane_id, removal);
}

/// Copies and correlates a prompt, preserving the draft until acknowledgement.
/// Example: `try agent_threads.submit(client, pane_id);`
pub fn submit(client: *Client, pane_id: core.PaneId) !void {
    if (request_lifecycle.hasPane(client, .agent_prompt, pane_id)) {
        return;
    }

    const intent = client.model.planAgentPrompt(pane_id) orelse return;
    const request_id = try client.request_lifecycle.nextId();
    try request_lifecycle.deliverAgentPrompt(client, .{
        .request_id = request_id,
        .pane_id = pane_id,
        .pane_generation = intent.pane_generation,
        .text = intent.text,
        .images = intent.images,
        .options = intent.options,
    }, .{
        .pane_id = pane_id,
        .pane_generation = intent.pane_generation,
        .attachment_generation = intent.attachment_generation,
        .location = intent.location,
        .composer_content_revision = intent.composer_content_revision,
    });
}

/// Cancels the current agent turn through runtime authority. Example: `try agent_threads.interrupt(client, pane_id);`
pub fn interrupt(client: *Client, pane_id: core.PaneId) !void {
    const pending = operation(client, pane_id) orelse return;
    if (request_lifecycle.hasPane(client, .agent_control, pane_id)) {
        return;
    }

    const request_id = try client.request_lifecycle.nextId();
    try request_lifecycle.deliver(client, .{
        .registration = .{ .request_id = request_id, .continuation = .{ .agent_control = pending } },
        .message = .{ .agent_interrupt = .{
            .request_id = request_id,
            .pane_id = pane_id,
            .pane_generation = pending.pane_generation,
        } },
    });
}

/// Resumes an advertised conversation without consuming the composer's draft.
/// Example: `try agent_threads.resumeConversation(client, pane_id, index);`
pub fn resumeConversation(client: *Client, pane_id: core.PaneId, index: u8) !void {
    const pending = operation(client, pane_id) orelse return;
    const pane = client.model.agentPane(pane_id) orelse return;
    const snapshot = pane.agent_thread orelse return;
    if (!snapshot.canResume() or index >= snapshot.recent.count or request_lifecycle.hasPane(client, .agent_control, pane_id) or request_lifecycle.hasPane(client, .agent_prompt, pane_id)) {
        return;
    }

    const request_id = try client.request_lifecycle.nextId();
    try request_lifecycle.deliver(client, .{
        .registration = .{ .request_id = request_id, .continuation = .{ .agent_control = pending } },
        .message = .{ .agent_resume = .{
            .request_id = request_id,
            .pane_id = pane_id,
            .pane_generation = pending.pane_generation,
            .expected_revision = snapshot.revision,
            .conversation_index = index,
        } },
    });
}

/// Answers the exact approval the user reviewed. Example: `try agent_threads.approve(client, decision);`
pub fn approve(client: *Client, decision: AgentDecision) !void {
    const pending = operation(client, decision.pane_id) orelse return;
    const pane = client.model.agentPane(decision.pane_id) orelse return;
    const thread = pane.agent_thread orelse return;
    const approval = thread.pending_approval orelse return;
    if (approval.id != decision.approval_id or request_lifecycle.hasPane(client, .agent_control, decision.pane_id)) {
        return;
    }

    const request_id = try client.request_lifecycle.nextId();
    try request_lifecycle.deliver(client, .{
        .registration = .{ .request_id = request_id, .continuation = .{ .agent_control = pending } },
        .message = .{ .agent_approval = .{
            .request_id = request_id,
            .pane_id = decision.pane_id,
            .pane_generation = pending.pane_generation,
            .approval_id = decision.approval_id,
            .accept = decision.accept,
        } },
    });
}

/// Requests the retained conversation after attachment or recovery. Example: `try agent_threads.query(client, pane_id);`
pub fn query(client: *Client, pane_id: core.PaneId) !void {
    const pending = operation(client, pane_id) orelse return;
    if (request_lifecycle.hasPane(client, .agent_query, pane_id)) {
        return;
    }

    const request_id = try client.request_lifecycle.nextId();
    try request_lifecycle.deliver(client, .{
        .registration = .{ .request_id = request_id, .continuation = .{ .agent_query = pending } },
        .message = .{ .query_agent_thread = .{
            .request_id = request_id,
            .pane_id = pane_id,
            .pane_generation = pending.pane_generation,
        } },
    });
}

/// Applies a borrowed snapshot before receive storage is reused. Example: `_ = try agent_threads.apply(client, snapshot);`
pub fn apply(client: *Client, snapshot: core.AgentThreadSnapshotView) !bool {
    return client.model.applyAgentThread(snapshot);
}

/// Consumes successful agent requests exactly once. Example: `try agent_threads.completed(client, reply);`
pub fn completed(client: *Client, reply: core.RequestCompleted) !void {
    const continuation = request_lifecycle.consume(client, reply.request_id) orelse return error.UnexpectedControlReply;
    switch (continuation) {
        .agent_prompt => |pending| {
            _ = client.model.completeAgentPrompt(pending);
        },
        .agent_control, .agent_query, .ignored => {},
        else => return error.UnexpectedControlReply,
    }
}

/// Sets runtime pane identity after the existing attachment flow commits.
/// Example: `try agent_threads.opened(client, opened);`
pub fn opened(client: *Client, opened_pane: core.PaneOpened) !void {
    if (client.model.identifyPane(opened_pane) and opened_pane.kind == .agent) {
        try query(client, opened_pane.pane_id);
    }
}

/// Moves transcript navigation independently from terminal scrollback. Example: `try agent_threads.scroll(client, id, 3);`
pub fn scroll(client: *Client, pane_id: core.PaneId, delta: f64) !void {
    _ = client.model.scrollAgentThread(pane_id, delta);
}

/// Chooses a model and its advertised default effort. Example: `try agent_threads.selectModel(client, id, model.idSlice());`
pub fn selectModel(client: *Client, pane_id: core.PaneId, model_id: []const u8) !void {
    _ = client.model.changeAgentOption(pane_id, .{ .model = model_id });
}

/// Chooses an effort the selected model supports. Example: `try agent_threads.selectEffort(client, id, effort);`
pub fn selectEffort(client: *Client, pane_id: core.PaneId, effort: core.AgentEffort) !void {
    _ = client.model.changeAgentOption(pane_id, .{ .effort = effort });
}

/// Changes permissions for this draft and its next turn. Example: `try agent_threads.selectAccess(client, id, .read_only);`
pub fn selectAccess(client: *Client, pane_id: core.PaneId, access: core.AgentAccess) !void {
    _ = client.model.changeAgentOption(pane_id, .{ .access = access });
}

fn operation(client: *const Client, pane_id: core.PaneId) ?AgentOperation {
    const pane = client.model.agentPane(pane_id) orelse return null;
    return .{
        .pane_id = pane_id,
        .pane_generation = pane.pane_generation,
        .attachment_generation = pane.attachment_generation,
        .location = pane.location,
    };
}
