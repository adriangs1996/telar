//! Wires workspace-list intent to its pure client-state transition.

const client_application = @import("application/root.zig");

const Client = @import("client.zig");
const toggle_workspace_list = client_application.toggle_workspace_list;

/// Wires one client model to the workspace-list use case.
///
/// ```zig
/// var use_case = handler(client);
/// _ = use_case.execute();
/// ```
pub fn handler(client: *Client) toggle_workspace_list.ToggleWorkspaceListHandler {
    return .{ .model = &client.model };
}
