const SpanView = @This();
const CellIterator = @import("CellIterator.zig");
start: u32,
cell_count: u32,
encoded_cells: []const u8,

pub fn cells(span: SpanView) CellIterator {
    return .{
        .decoder = .init(span.encoded_cells),
        .remaining = span.cell_count,
    };
}
