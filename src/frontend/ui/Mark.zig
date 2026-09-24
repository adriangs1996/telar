const cellgrid = @import("cellgrid");
const data = @import("model");
const Mark = @This();

area: cellgrid.Rect,
icon: data.icons.Icon,
foreground: [3]u8,
background: [3]u8,
