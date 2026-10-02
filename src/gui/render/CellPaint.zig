//! Fully resolved visual inputs. Future selection/search styling belongs in
//! `cell.style` before lookup, so it participates in damage automatically.
const cellgrid = @import("cellgrid");
const gfx = @import("gfx");
const Rect = gfx.Rect;
cell: cellgrid.Cell,
rect: Rect,
/// The shaping run around the cell: a hash of the text of every cell
/// shaped with it and the cell's place among them, so editing any cell of
/// a ligature repaints all of it. Zero for a cell shaped alone.
context: u64 = 0,
