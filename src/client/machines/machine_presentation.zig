//! Which machine a window presents (docs/flows/machine-presentation.md).
//! The presented client attaches panes and receives their screens; a hidden
//! one keeps metadata only: workspace list, agents, notifications and
//! metrics. Hiding a machine leaves its workspace, remembering it; showing
//! it again reopens that workspace, or opens its first pane when it never
//! had one.
const Client = @import("../execution/Client.zig");
const client_layout = @import("../workspace/client_layout.zig");
const workspace_handoff = @import("../workspace/workspace_handoff.zig");
const client_tests = @import("../execution/client_tests.zig");

/// Presents the client's machine: opens the first pane it deferred, or the
/// workspace it left.
///
/// ```zig
/// try machine_presentation.show(client);
/// ```
pub fn show(client: *Client) !void {
    client.presented = true;
    client.leave_pending = false;
    if (client.model.runtime_link.phase != .connected) {
        return;
    }

    if (client.open_deferred) {
        client.open_deferred = false;
        const restored = client.deferred_layout;
        client.deferred_layout = null;
        return client_layout.openInitialPane(client, restored);
    }

    if (client.model.workspace != null) {
        return;
    }

    const workspace = client.left_workspace orelse return;
    client.left_workspace = null;
    _ = try workspace_handoff.requestWorkspace(client, workspace);
}

/// Stops presenting the client's machine: leaves its workspace so the
/// runtime stops streaming its panes. With requests in flight it waits;
/// `settle` finishes it later.
///
/// ```zig
/// try machine_presentation.hide(client);
/// ```
pub fn hide(client: *Client) !void {
    client.presented = false;
    client.leave_pending = true;
    try settle(client);
}

/// Finishes leaving a hidden client's workspace once nothing is in flight.
/// The adapter calls it after each of the client's events.
///
/// ```zig
/// try machine_presentation.settle(client);
/// ```
pub fn settle(client: *Client) !void {
    if (!client.leave_pending or client.presented) {
        return;
    }

    const location = client.model.workspace orelse {
        client.leave_pending = false;
        return;
    };

    if (!client.model.request_lifecycle.tracker.isEmpty()) {
        return;
    }

    client.left_workspace = switch (location) {
        .workspace => |workspace| workspace,
        .worktree => null,
    };
    _ = try workspace_handoff.leaveWorkspace(client);
    client.leave_pending = false;
}

test "a hidden machine defers its first pane and leaves its workspace" {
    try client_tests.hiddenMachineDefersAndLeaves(show, hide);
}
