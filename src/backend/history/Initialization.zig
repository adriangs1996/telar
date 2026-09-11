const std = @import("std");
const TerminalSizeType = @import("telar-core").TerminalSize;
const TableType = @import("telar-core").Table;
const builtin_table_module = @import("telar-core").builtin_table;
const Initialization = @This();

io: std.Io,
gpa: std.mem.Allocator,
cwd: []const u8,
size: TerminalSizeType,
manifests: *const TableType = &builtin_table_module,
capture_output: bool = false,
