const Client = @import("../../AttachedClient.zig");
const Commit = @import("../../panes/PresentationCommit.zig");
const core = @import("telar-core");

/// Retires exactly the delivered pane generations before returning resource credit.
/// Example: `try presentation_delivery.apply(client, delivery.commit);`
pub fn apply(client: *Client, commit: Commit) !void {
    if (commit.len > core.max_panes_per_tab) {
        return error.InvalidPresentationCommit;
    }

    _ = client.model.commitPresentation(commit);
    try client.flushGraphicsCredits();
}
