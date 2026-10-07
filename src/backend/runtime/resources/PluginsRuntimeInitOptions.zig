const std = @import("std");
const ServiceSpec = @import("../../plugins/ServiceSpec.zig");

io: std.Io,
gpa: std.mem.Allocator,
specs: []const ServiceSpec,
