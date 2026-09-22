const core = @import("telar-core");
const std = @import("std");
const ScreenResize = @This();

gpa: std.mem.Allocator,
screen: *core.Buffer,
damaged_rows: *[]bool,
cols: u16,
rows: u16,
