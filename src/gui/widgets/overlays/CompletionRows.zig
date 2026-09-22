//! The completion list of the new-context form as the overlay paints it.
const shared_model = @import("model");
const client = @import("telar-client");
const CompletionRows = @This();

entries: []const shared_model.PathCompletionEntry,
selected: u16,
/// The directory field owns input, so the selection is highlighted.
active: bool,
