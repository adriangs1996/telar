const RuntimeState = @This();
const source_namespace = @import("history.zig");
const std = @import("std");
const history = @import("../../history/root.zig");
io: source_namespace.Io,
gpa: std.mem.Allocator,
service: history.Service,
