const DecoderType = @import("Decoder.zig");
const SpanView = @import("SpanView.zig");
const SpanIterator = @This();

decoder: DecoderType,
remaining: u16,

pub fn next(iterator: *SpanIterator) error{Truncated}!?SpanView {
    if (iterator.remaining == 0) {
        return null;
    }
    iterator.remaining -= 1;

    const start = try iterator.decoder.readInt(u32);
    const count = try iterator.decoder.readInt(u32);
    const encoded_length = try iterator.decoder.readInt(u32);
    const encoded_cells = try iterator.decoder.readBytes(encoded_length);
    return .{
        .start = start,
        .cell_count = count,
        .encoded_cells = encoded_cells,
    };
}
