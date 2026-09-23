const id = @import("../id.zig");
const GraphicsCredit = @This();

pane_id: id.PaneId,
bytes: u64,

pub fn validateWire(self: GraphicsCredit) !void {
    if (self.bytes == 0) {
        return error.InvalidGraphicsCredit;
    }
}
