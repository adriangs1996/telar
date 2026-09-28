//! One top-level component drawn on its own row.
const cellgrid = @import("cellgrid");
const data = @import("model");
const ComponentPlacement = @This();

index: usize,
area: cellgrid.Rect,
facts: *const data.BarFacts,
