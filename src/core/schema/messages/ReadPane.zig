const id = @import("../id.zig");
const types = @import("../types.zig");
/// Bounded plain-text read of one exact pane generation.
const ReadPane = @This();

request_id: id.RequestId,
pane_id: id.PaneId,
pane_generation: u64,
rows: u16,
source: types.PaneTextSource,

pub fn validateWire(message: ReadPane) !void {
    if (message.rows == 0 or message.rows > types.max_pane_text_rows) {
        return error.InvalidPaneTextRows;
    }
}
