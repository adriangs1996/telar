const std = @import("std");
const ServiceType = @import("../../history/Service.zig");
const RuntimeState = @This();

io: std.Io,
gpa: std.mem.Allocator,
service: ServiceType,
