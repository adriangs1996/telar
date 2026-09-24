//! A compact encoding for runs of `cellgrid` cells: a packed header byte per
//! cell, a style written only when it changes, and colors that carry only
//! the channels their kind needs. Encoding never allocates and can stop at a
//! caller's size limit; decoding validates every cell.

const cell_run = @import("cell_run.zig");

pub const CellReader = @import("CellReader.zig");
pub const cell_header_size = cell_run.cell_header_size;
pub const max_style_size = cell_run.max_style_size;
pub const max_cell_size = cell_run.max_cell_size;
pub const style_changed_bit = cell_run.style_changed_bit;
pub const encode = cell_run.encode;
pub const decodeCell = cell_run.decodeCell;
pub const encodedCellsSize = cell_run.encodedCellsSize;
pub const encodedCellSize = cell_run.encodedCellSize;

test {
    _ = @import("CellReader.zig");
    _ = @import("cell_run.zig");
    _ = @import("cell_run_tests.zig");
}
