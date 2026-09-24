const cellgrid = @import("cellgrid");
const std = @import("std");
const ScreenResize = @This();

gpa: std.mem.Allocator,
screen: *cellgrid.Buffer,
damaged_rows: *[]bool,
cols: u16,
rows: u16,
