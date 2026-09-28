//! A filled chrome surface with rounded corners, in cell coordinates.
const cellgrid = @import("cellgrid");
radius: f32,
color: cellgrid.Color,
/// Opacity of the fill, so a surface can tint whatever lies beneath it.
alpha: f32 = 1,
