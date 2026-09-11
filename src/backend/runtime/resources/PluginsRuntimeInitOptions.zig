const std = @import("std");
const ServiceSpec = @import("../../plugins/ServiceSpec.zig");
const InitOptions = @This();

io: std.Io,
gpa: std.mem.Allocator,
specs: []const ServiceSpec,
