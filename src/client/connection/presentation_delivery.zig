const data = @import("model");
const Client = @import("../AttachedClient.zig");
const core = @import("telar-core");

/// Retires exactly the delivered pane generations; the next `flush` returns
/// the resource credit they held.
/// Example: `try presentation_delivery.apply(client, delivery.commit);`
pub fn apply(model: *data.ClientModel, commit: data.PresentationCommit) !void {
    if (commit.len > core.max_panes_per_tab) {
        return error.InvalidPresentationCommit;
    }

    _ = model.commitPresentation(commit);
}
