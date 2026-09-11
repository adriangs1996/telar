const std = @import("std");
const BufferType = @import("telar-core").Buffer;
const ScreenResize = @This();

gpa: std.mem.Allocator,
screen: *BufferType,
damaged_rows: *[]bool,
cols: u16,
rows: u16,
