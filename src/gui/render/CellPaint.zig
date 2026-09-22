//! Fully resolved visual inputs. Future selection/search styling belongs in
//! `cell.style` before lookup, so it participates in damage automatically.
const core = @import("telar-core");
cell: core.Cell,
rect: @import("Rect.zig"),
