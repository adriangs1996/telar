//! Client startup: the first pane request the client sends once it knows its
//! geometry.
const lifecycle = @import("lifecycle.zig");
const data = @import("model");
const core = @import("telar-core");
const Client = @import("../execution/Client.zig");

pub fn initialPaneRequest(client: *Client, restored: ?data.SavedLayout, size: core.TerminalSize) data.ConnectionDelivery {
    const fallback_workspace: ?core.WorkspaceId = if (restored) |saved| switch (saved.location.workspace) {
        .workspace => |workspace_id| workspace_id,
        .worktree => null,
    } else null;

    return .{
        .registration = .{
            .request_id = lifecycle.initial_request_id,
            .continuation = .{
                .initial_open = .{
                    .fallback_workspace = fallback_workspace,
                },
            },
        },
        .message = .{
            .open_pane = .{
                .request_id = lifecycle.initial_request_id,
                .target = if (restored) |saved| .{
                    .pane = saved.pane_id,
                } else .default,
                .size = size,
                .launch = if (restored == null) .{
                    .cwd = client.options.cwd,
                    .arguments = client.options.arguments,
                } else null,
            },
        },
    };
}
