const ScreenResize = @This();
const std = @import("std");
const core = @import("telar-core");
gpa: std.mem.Allocator,
screen: *core.ui.Buffer,
damaged_rows: *[]bool,
cols: u16,
rows: u16,
