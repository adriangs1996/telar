//! Tab selection: activates a tab and requests what it needs to show.
const data = @import("model");
const pane_focus = @import("../panes/pane_focus.zig");
const tab_removal = @import("tab_removal.zig");
const tab_snapshot = @import("tab_snapshot.zig");
const Client = @import("../execution/Client.zig");

/// Selects canonical identity, retires previous input authorities and requests current membership. Example: `_ = try select(client, command);`
/// Example: `_ = try tab_selection.selectTab(app, command);`
pub fn selectTab(client: *Client, command: data.SelectTab) !?data.TabSelection {
    if (client.model.request_lifecycle.tracker.has(.tab_snapshot)) {
        return null;
    }

    const selection = data.tab_selection.commitSelection(&client.model, command.target) catch |err| switch (err) {
        error.NoActiveTab, error.TabNotFound => return null,
    } orelse return null;
    try tab_removal.detachTab(client, selection.previous);

    const selected = client.model.tabs.find(selection.selected.tab_id) orelse return error.StaleTabSelection;
    var panes = client.model.panes.iterate(client.model.tabs.location[selected].tab_id);
    while (panes.next()) |pane| {
        try client.graphics.setPaneVisible(pane.id, true);
    }

    try pane_focus.synchronizeActivePane(client);
    try tab_snapshot.requestTabSnapshot(&client.model, selection.selected);
    return selection;
}
