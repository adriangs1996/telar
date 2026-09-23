const Decoder = @import("Decoder.zig");
const Style = @import("../ui/Style.zig");
const Cell = @import("../ui/Cell.zig");
const frame_support = @import("frame_support.zig");
const CellIterator = @This();

decoder: Decoder,
remaining: u32,
style: ?Style = null,

pub fn next(self: *CellIterator) !?Cell {
    if (self.remaining == 0) {
        return null;
    }
    self.remaining -= 1;
    const cell = try frame_support.decodeCell(&self.decoder, &self.style);
    // The span header promised exactly `cell_count` cells; leftover bytes
    // after the last one are corruption, not padding.
    if (self.remaining == 0) {
        try self.decoder.ensureEnd();
    }
    return cell;
}
