//! Fully resolved visual inputs. Future selection/search styling belongs in
//! `cell.style` before lookup, so it participates in damage automatically.
const cellgrid = @import("cellgrid");
const gfx = @import("gfx");
const Rect = gfx.Rect;
cell: cellgrid.Cell,
rect: Rect,
