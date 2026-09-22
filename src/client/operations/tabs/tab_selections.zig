const Client = @import("../../AttachedClient.zig");
const SelectTab = @import("../../application/tabs/SelectTab.zig");
const TabSelection = @import("../../model/TabSelection.zig");

/// Selects canonical identity, retires previous input authorities and requests current membership. Example: `_ = try select(client, command);`
pub fn select(client: *Client, command: SelectTab) !?TabSelection {
    if (client.request_lifecycle.tracker.has(.tab_snapshot)) {
        return null;
    }

    const selection = client.model.selectTab(command.target) catch |err| switch (err) {
        error.NoActiveTab, error.TabNotFound => return null,
    } orelse return null;
    try client.detachTab(selection.previous);

    const selected = client.model.workspace.find(selection.selected.tab_id) orelse return error.StaleTabSelection;
    var panes = selected.model.paneIterator();
    while (panes.next()) |pane| {
        try client.graphics.setPaneVisible(pane.id, true);
    }

    try client.synchronizeActivePane();
    try client.requestTabSnapshot(selection.selected);
    return selection;
}
