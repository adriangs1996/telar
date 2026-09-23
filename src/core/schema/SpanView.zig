const CellIterator = @import("CellIterator.zig");
const SpanView = @This();

start: u32,
cell_count: u32,
encoded_cells: []const u8,

pub fn cells(self: SpanView) CellIterator {
    return .{
        .decoder = .init(self.encoded_cells),
        .remaining = self.cell_count,
    };
}
