const Decoder = @import("Decoder.zig");
const CellIterator = @import("CellIterator.zig");
const SpanIterator = @This();

decoder: Decoder,
remaining: u16,

pub fn next(self: *SpanIterator) error{Truncated}!?SpanView {
    if (self.remaining == 0) {
        return null;
    }
    self.remaining -= 1;

    const start = try self.decoder.readInt(u32);
    const count = try self.decoder.readInt(u32);
    const encoded_length = try self.decoder.readInt(u32);
    const encoded_cells = try self.decoder.readBytes(encoded_length);
    return .{
        .start = start,
        .cell_count = count,
        .encoded_cells = encoded_cells,
    };
}

const SpanView = struct {
    start: u32,
    cell_count: u32,
    encoded_cells: []const u8,

    pub fn cells(self: SpanView) CellIterator {
        return .{
            .decoder = .init(self.encoded_cells),
            .remaining = self.cell_count,
        };
    }
};
