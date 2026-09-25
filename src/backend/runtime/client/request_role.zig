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
        .query_history,
        .import_history,
        .delete_history,
        .prune_history,
        .read_history_output,
        .history_stats,
        .show_notification,
        .query_change_review,
        .change_review_command,
        .report_change_review_sample,
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

test "runtime observers cannot be mistaken for interactive clients" {
    try std.testing.expectEqual(RequestClass.control, classifyMessage(.{ .request_runtime_state = .{ .client_identity = @enumFromInt(1), .interactive = false } }));
    try std.testing.expectEqual(RequestClass.ui, classifyMessage(.{ .request_runtime_state = .{ .client_identity = @enumFromInt(1) } }));
}

test "interactive mutations and control queries keep distinct admission roles" {
    const ui = [_]Tag{ .open_pane, .pane_input, .pane_resize, .frame_ack, .configure_graphics, .update_client_layout };
    const control = [_]Tag{ .runtime_stop, .query_clients, .read_pane, .report_agent_session, .request_pane_focus, .query_change_review };
    for (ui) |tag| {
        try std.testing.expectEqual(RequestClass.ui, classify(tag));
    }
    for (control) |tag| {
        try std.testing.expectEqual(RequestClass.control, classify(tag));
    }
}
