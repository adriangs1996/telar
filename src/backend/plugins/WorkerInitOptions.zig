const std = @import("std");
const ServiceSpec = @import("ServiceSpec.zig");
const Result = @import("Result.zig");
const WorkerInitOptions = @This();

gpa: std.mem.Allocator,
spec: ServiceSpec,
results: *std.Io.Queue(*Result),
