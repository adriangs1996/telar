//! Fully resolved visual inputs. Future selection/search styling belongs in
//! `cell.style` before lookup, so it participates in damage automatically.
const core = @import("telar-core");
const gfx = @import("gfx");
const Rect = gfx.Rect;
cell: core.Cell,
rect: Rect,
