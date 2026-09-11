const std = @import("std");
const TerminalSizeType = @import("telar-core").TerminalSize;
const InitOptions = @This();

io: std.Io,
allocator: std.mem.Allocator,
size: TerminalSizeType,
