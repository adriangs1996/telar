//! Reads the cells of one encoded run whose count the caller already knows.
const bytecodec = @import("bytecodec");
const cellgrid = @import("cellgrid");
const cell_run = @import("cell_run.zig");
const Decoder = bytecodec.Decoder;
const Cell = cellgrid.Cell;
const Style = cellgrid.Style;
const CellReader = @This();

decoder: Decoder,
remaining: u32,
style: ?Style = null,

/// Reads `count` cells from `bytes`, which the reader borrows.
///
/// ```zig
/// var reader = CellReader.init(encoded_cells, cell_count);
/// ```
pub fn init(bytes: []const u8, count: u32) CellReader {
    return .{
        .decoder = .init(bytes),
        .remaining = count,
    };
}

/// Returns the next cell, or null after the last. Bytes left after the last
/// promised cell are corruption, not padding.
///
/// ```zig
/// while (try reader.next()) |cell| draw(cell);
/// ```
pub fn next(self: *CellReader) !?Cell {
    if (self.remaining == 0) {
        return null;
    }

    self.remaining -= 1;

    const cell = try cell_run.decodeCell(&self.decoder, &self.style);
    if (self.remaining == 0) {
        try self.decoder.ensureEnd();
    }

    return cell;
}
