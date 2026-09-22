const core = @import("telar-core");
const std = @import("std");
const vt = @import("ghostty-vt");
const Initialization = @This();

io: std.Io,
allocator: std.mem.Allocator,
size: core.TerminalSize,
storage_limit: usize,
payload_limit: usize,
write_pty: ?*const fn (*vt.TerminalStream.Handler, [:0]const u8) void,
