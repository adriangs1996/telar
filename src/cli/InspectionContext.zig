const InspectionContext = @This();
const source_namespace = @import("proxy.zig");
const std = @import("std");
io: source_namespace.Io,
gpa: std.mem.Allocator,
environ: std.process.Environ,

fn fromProcess(init: std.process.Init) InspectionContext {
    return .{ .io = init.io, .gpa = init.gpa, .environ = init.minimal.environ };
}
