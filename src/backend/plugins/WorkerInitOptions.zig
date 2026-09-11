const std = @import("std");
const ServiceSpec = @import("ServiceSpec.zig");
const ResultType = @import("Result.zig");
const WorkerInitOptions = @This();

gpa: std.mem.Allocator,
spec: ServiceSpec,
results: *std.Io.Queue(*ResultType),
