const Initialization = @This();
const source_namespace = @import("root.zig");
const std = @import("std");
const vt = @import("ghostty-vt");
io: source_namespace.Io,
allocator: std.mem.Allocator,
size: source_namespace.schema.TerminalSize,
storage_limit: usize,
payload_limit: usize,
write_pty: ?*const fn (*vt.TerminalStream.Handler, [:0]const u8) void,
