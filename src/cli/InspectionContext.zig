const std = @import("std");
const InspectionContext = @This();

io: std.Io,
gpa: std.mem.Allocator,
environ: std.process.Environ,

pub fn fromProcess(init: std.process.Init) InspectionContext {
    return .{ .io = init.io, .gpa = init.gpa, .environ = init.minimal.environ };
}
