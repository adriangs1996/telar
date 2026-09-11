const CellIterator = @This();
const wire = @import("wire.zig");
const ui = @import("../ui/root.zig");
const source_namespace = @import("frame_support.zig");
decoder: wire.Decoder,
remaining: u32,
style: ?ui.Style = null,

pub fn next(iterator: *CellIterator) !?ui.Cell {
    if (iterator.remaining == 0) {
        return null;
    }
    iterator.remaining -= 1;
    const cell = try source_namespace.decodeCell(&iterator.decoder, &iterator.style);
    // The span header promised exactly `cell_count` cells; leftover bytes
    // after the last one are corruption, not padding.
    if (iterator.remaining == 0) {
        try iterator.decoder.ensureEnd();
    }
    return cell;
}
