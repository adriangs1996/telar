const GraphicsCredit = @This();
const source_namespace = @import("graphics.zig");
pane_id: source_namespace.PaneId,
bytes: u64,

pub fn validateWire(message: GraphicsCredit) !void {
    if (message.bytes == 0) {
        return error.InvalidGraphicsCredit;
    }
}
