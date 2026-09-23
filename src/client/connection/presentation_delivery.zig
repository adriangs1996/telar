const data = @import("model");
const Client = @import("../AttachedClient.zig");
const core = @import("telar-core");

/// Retires exactly the delivered pane generations before returning resource credit.
/// Example: `try presentation_delivery.apply(client, delivery.commit);`
pub fn apply(client: *Client, commit: data.PresentationCommit) !void {
    if (commit.len > core.max_panes_per_tab) {
        return error.InvalidPresentationCommit;
    }

    _ = client.model.commitPresentation(commit);
    try client.flushGraphicsCredits();
}
