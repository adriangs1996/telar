const core = @import("telar-core");
const Delivery = @import("../../delivery/Delivery.zig");
const Handler = @import("../../application/commands/AgentThreadHandler.zig");
const Action = @import("../../application/commands/agent_thread.zig").Action;

delivery: *Delivery,
handler: *Handler,

/// Translates one agent control, preserving failures for the composer draft.
/// Example: `try controller.handle(prompt);`.
pub fn handle(controller: *@This(), request: anytype) !void {
    const T = @TypeOf(request);
    const action: Action = if (T == core.AgentPrompt)
        .{ .prompt = .{ .text = request.text, .options = request.options, .images = request.images } }
    else if (T == core.AgentInterrupt)
        .interrupt
    else if (T == core.AgentResume)
        .{ .resume_conversation = request.conversation_index }
    else if (T == core.AgentApproval)
        .{ .approval = .{ .id = request.approval_id, .accepted = request.accept } }
    else if (T == core.QueryAgentThread)
        .query
    else
        @compileError("unsupported agent control");
    const key = controller.handler.execute(.{
        .pane = .{ .id = request.pane_id, .generation = request.pane_generation },
        .action = action,
    }) catch |err| {
        try controller.delivery.responses.push(.{ .request_failed = .{
            .request_id = request.request_id,
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
        controller.delivery.requestAgentThread(key);
    }
    try controller.delivery.responses.push(.{ .request_completed = .{ .request_id = request.request_id } });
}
