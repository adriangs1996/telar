const DecoderType = @import("Decoder.zig");
const StyleType = @import("../ui/Style.zig");
const CellType = @import("../ui/Cell.zig");
const frame_support = @import("frame_support.zig");
const CellIterator = @This();

decoder: DecoderType,
remaining: u32,
style: ?StyleType = null,

pub fn next(iterator: *CellIterator) !?CellType {
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
