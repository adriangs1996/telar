const Client = @import("../../AttachedClient.zig");
const PaneId = @import("telar-core").PaneId;

/// Releases exact pane authorities before physical resources; repeated release is harmless. Example: `release(client, pane_id);`
pub fn release(client: *Client, pane_id: PaneId) void {
    _ = client.model.releaseCopyMode(pane_id);
    _ = client.model.releasePanePaste(pane_id);
    _ = client.model.releaseReportedPaneFocus(pane_id);
    client.graphics.clearPane(pane_id);
}
