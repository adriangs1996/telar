const Client = @import("../../AttachedClient.zig");
const SelectTab = @import("../../application/tabs/SelectTab.zig");
const TabSelection = @import("../../model/TabSelection.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const tab_attachments = @import("tab_attachments.zig");
const active_pane_resources = @import("../panes/active_pane_resources.zig");

/// Selects canonical identity, retires previous input authorities and requests current membership. Example: `_ = try select(client, command);`
pub fn select(client: *Client, command: SelectTab) !?TabSelection {
    if (request_lifecycle.has(client, .tab_snapshot)) {
        return null;
    }

    const selection = client.model.selectTab(command.target) catch |err| switch (err) {
        error.NoActiveTab, error.TabNotFound => return null,
    } orelse return null;
    try tab_attachments.detach(client, selection.previous);

    const selected = client.model.workspace.find(selection.selected.tab_id) orelse return error.StaleTabSelection;
    var panes = selected.model.paneIterator();
    while (panes.next()) |pane| {
        try client.graphics.setPaneVisible(pane.id, true);
    }

    try active_pane_resources.synchronize(client);
    try request_lifecycle.requestTabSnapshot(client, selection.selected);
    return selection;
}
