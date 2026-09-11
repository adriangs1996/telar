const std = @import("std");
const ServiceSpec = @import("ServiceSpec.zig");
const InitOptions = @This();

io: std.Io,
gpa: std.mem.Allocator,
specs: []const ServiceSpec,
