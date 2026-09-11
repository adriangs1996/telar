/// Bounded plain-text read of one exact pane generation.
const ReadPane = @This();
const source_namespace = @import("pane.zig");
const types = @import("../types.zig");
request_id: source_namespace.RequestId,
pane_id: source_namespace.PaneId,
pane_generation: u64,
rows: u16,
source: source_namespace.PaneTextSource,

pub fn validateWire(message: ReadPane) !void {
    if (message.rows == 0 or message.rows > types.max_pane_text_rows) {
        return error.InvalidPaneTextRows;
    }
}
