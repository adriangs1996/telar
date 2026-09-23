const Decoder = @import("Decoder.zig");
const SpanView = @import("SpanView.zig");
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
