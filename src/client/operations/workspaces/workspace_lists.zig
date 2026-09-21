//! Decodes and reconciles the runtime workspace list.

const Client = @import("../../AttachedClient.zig");
const WorkspaceListViewType = @import("telar-core").WorkspaceListView;
const workspace_list_snapshot = @import("../../application/workspaces/workspace_list_snapshot.zig");
const ApplicationWorkspacesWorkspaceListSnapshotOutcome = @import("../../application/workspaces/workspace_list_snapshot.zig").Outcome;
const max_workspace_list_entries_module = @import("telar-core").max_workspace_list_entries;
const EntryInputType = @import("../../workspace/EntryInput.zig");

/// Decodes one validated wire view into bounded domain inputs and reconciles
/// it through the model. A rejected snapshot keeps the
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

    const commit = client.model.reconcileWorkspaceList(.{
        .revision = list.revision,
        .entries = entries[0..count],
    }) catch |err| {
        const rejection = workspace_list_snapshot.classifyRejection(err) orelse return err;
        return .{ .rejected = rejection };
    };

    return if (commit) |value| .{ .applied = value } else .stale;
}
