const InitOptions = @This();
const source_namespace = @import("service_support.zig");
const std = @import("std");
const Spec = @import("ServiceSpec.zig");
io: source_namespace.Io,
gpa: std.mem.Allocator,
specs: []const Spec,
