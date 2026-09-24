const std = @import("std");
const GraphicsEffect = @This();

context: *anyopaque,
write: *const fn (*anyopaque, *std.Io.Writer) std.Io.Writer.Error!usize,
