const Decoder = @import("Decoder.zig");
const Style = @import("../ui/Style.zig");
const Cell = @import("../ui/Cell.zig");
const frame_support = @import("frame_support.zig");
const CellIterator = @This();

decoder: Decoder,
remaining: u32,
style: ?Style = null,

pub fn next(iterator: *CellIterator) !?Cell {
    if (iterator.remaining == 0) {
        return null;
    }
    iterator.remaining -= 1;
    const cell = try frame_support.decodeCell(&iterator.decoder, &iterator.style);
    // The span header promised exactly `cell_count` cells; leftover bytes
    // after the last one are corruption, not padding.
    if (iterator.remaining == 0) {
        try iterator.decoder.ensureEnd();
    }
    return cell;
}
