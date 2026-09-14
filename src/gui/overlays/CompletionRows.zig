//! The completion list of the new-context form as the overlay paints it.
const client = @import("telar-client");
const CompletionRows = @This();

entries: []const client.PathCompletionEntry,
selected: u16,
/// The directory field owns input, so the selection is highlighted.
active: bool,
