const Client = @import("../../AttachedClient.zig");
const runtime_transport = @import("../../entrypoints/runtime_io.zig");

pub const Outcome = enum { applied, unchanged };

/// Commits reporting ownership before emitting focus-out and focus-in. Example: `_ = try sync(client);`
pub fn sync(client: *Client) !Outcome {
    const transition = client.model.syncReportedPaneFocus() orelse return .unchanged;
    if (transition.focus_out) |pane_id| {
        try runtime_transport.enqueueInput(client, pane_id, "\x1b[O");
    }

    if (transition.focus_in) |pane_id| {
        try runtime_transport.enqueueInput(client, pane_id, "\x1b[I");
    }

    return .applied;
}

/// Clears focus ownership before detachment and sends the matching focus-out. Example: `_ = try clear(client);`
pub fn clear(client: *Client) !Outcome {
    const transition = client.model.clearReportedPaneFocus() orelse return .unchanged;
    if (transition.focus_out) |pane_id| {
        try runtime_transport.enqueueInput(client, pane_id, "\x1b[O");
    }

    return .applied;
}

/// Forgets invalidated focus without sending child input. Example: `_ = retire(client);`
pub fn retire(client: *Client) Outcome {
    return if (client.model.forgetReportedPaneFocus()) .applied else .unchanged;
}
