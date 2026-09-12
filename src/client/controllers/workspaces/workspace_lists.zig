//! Adapts runtime workspace-list messages to the client application boundary.

const Client = @import("../../AttachedClient.zig");
const WorkspaceListViewType = @import("telar-core").WorkspaceListView;
const ApplicationWorkspacesWorkspaceListSnapshotOutcome = @import("../../application/workspaces/workspace_list_snapshot.zig").Outcome;
const max_workspace_list_entries_module = @import("telar-core").max_workspace_list_entries;
const EntryInputType = @import("../../workspace/EntryInput.zig");
const ReconcileWorkspaceListHandlerType = @import("../../application/workspaces/ReconcileWorkspaceListHandler.zig");

/// Decodes one validated wire view into bounded domain inputs and reconciles
/// it through the application handler. An application rejection keeps the
/// previous replica available until a later runtime revision arrives.
///
/// ```zig
/// _ = try apply(client, list);
/// ```
pub fn apply(client: *Client, list: WorkspaceListViewType) !ApplicationWorkspacesWorkspaceListSnapshotOutcome {
    var entries: [max_workspace_list_entries_module]EntryInputType = undefined;
    var count: usize = 0;
    var iterator = list.entries();
    while (try iterator.next()) |entry| {
        entries[count] = .{
            .workspace = entry.workspace,
            .name = entry.name,
            .path = entry.path,
            .tab_count = entry.tab_count,
            .branch = entry.branch,
            .dirty = entry.dirty,
        };
        count += 1;
    }

    var use_case = handler(client);

    return use_case.execute(.{
        .revision = list.revision,
        .entries = entries[0..count],
    });
}

fn handler(client: *Client) ReconcileWorkspaceListHandlerType {
    return .{ .model = &client.model };
}
