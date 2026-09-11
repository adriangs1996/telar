const RuntimeState = @This();
const source_namespace = @import("engine.zig");
const std = @import("std");
const engine = @import("../../engine/root.zig");
io: source_namespace.Io,
gpa: std.mem.Allocator,
service: engine.Service,
