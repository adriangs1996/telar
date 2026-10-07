//! Determines a client connection's role from its first decoded request.
const std = @import("std");
const core = @import("telar-core");

pub const Tag = std.meta.Tag(core.ClientMessage);
pub const RequestClass = enum { ui, control };

/// Classifies admission before a connection acquires its retained role.
/// Example: `const role = classify(.pane_input);`.
pub fn classify(tag: Tag) RequestClass {
    return switch (tag) {
        .runtime_stop,
        .execution_request,
        .query_history,
        .import_history,
        .delete_history,
        .prune_history,
        .read_history_output,
        .history_stats,
        .show_notification,

        .request_client_command,
        .detach_client,
        .query_clients,
        .query_agents,
        .search_pane,
        .read_pane,
        .send_pane_text,
        .report_agent_session,
        .report_agent,
        .report_agent_command,
        .report_agent_title,
        .request_pane_focus,
        .register_worktree,
        .launch_worktree,
        .launch_tab,
        .forget_worktree,
        .interrupt_agent,
        .report_agent_progress,
        .verify_pane_descent,
        .query_limits,
        // A window reports only after it attached; a first report comes
        // from a command, whose notice the runtime then shows.
        .report_limit,
        => .control,
        else => .ui,
    };
}

/// Resolves observer subscriptions before a session acquires a role. Example: `const role = classifyMessage(message);`
pub fn classifyMessage(message: core.ClientMessage) RequestClass {
    if (message == .request_runtime_state and !message.request_runtime_state.interactive) {
        return .control;
    }

    return classify(std.meta.activeTag(message));
}
