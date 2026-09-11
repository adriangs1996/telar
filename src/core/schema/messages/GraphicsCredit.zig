const id = @import("../id.zig");
const GraphicsCredit = @This();

pane_id: id.PaneId,
bytes: u64,

pub fn validateWire(message: GraphicsCredit) !void {
    if (message.bytes == 0) {
        return error.InvalidGraphicsCredit;
    }
}
