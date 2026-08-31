//! Adapts runtime workspace-list messages to the client application boundary.

const core = @import("telar-core");
const client_application = @import("application/root.zig");
const workspace_list = @import("../workspace/root.zig").workspace_list;

const Client = @import("client.zig");
const schema = core.schema;
const workspace_list_snapshot = client_application.workspace_list_snapshot;

pub const ApplyOutcome = workspace_list_snapshot.Outcome;

/// Decodes one validated wire view into bounded domain inputs and reconciles
/// it through the application handler. An application rejection keeps the
/// previous replica available until a later runtime revision arrives.
///
/// ```zig
/// _ = try apply(client, list);
/// ```
pub fn apply(client: *Client, list: schema.WorkspaceListView) !ApplyOutcome {
    var entries: [schema.max_workspace_list_entries]workspace_list.EntryInput = undefined;
    var count: usize = 0;
    var iterator = list.entries();
    while (try iterator.next()) |entry| {
        entries[count] = .{
            .workspace = entry.workspace,
            .name = entry.name,
            .path = entry.path,
            .tab_count = entry.tab_count,
        };
        count += 1;
    }

    var use_case = handler(client);

    return use_case.execute(.{
        .revision = list.revision,
        .entries = entries[0..count],
    });
}

fn handler(client: *Client) workspace_list_snapshot.ReconcileWorkspaceListHandler {
    return .{ .model = &client.model };
}
