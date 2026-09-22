const core = @import("telar-core");
const std = @import("std");
const Initialization = @This();

io: std.Io,
gpa: std.mem.Allocator,
cwd: []const u8,
size: core.TerminalSize,
manifests: *const core.Table = &core.builtin_table,
capture_output: bool = false,
