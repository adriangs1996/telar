const std = @import("std");
const TerminalSizeType = @import("telar-core").TerminalSize;
const vt = @import("ghostty-vt");
const Initialization = @This();

io: std.Io,
allocator: std.mem.Allocator,
size: TerminalSizeType,
storage_limit: usize,
payload_limit: usize,
write_pty: ?*const fn (*vt.TerminalStream.Handler, [:0]const u8) void,
