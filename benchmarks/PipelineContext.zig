const frontend = @import("telar-frontend");
const std = @import("std");
const Fixture = @import("Fixture.zig");
const main = @import("main.zig");
const PipelineContext = @This();

screen: frontend.Screen,
payloads: [2][]const u8,
output: []u8,

pub fn init(gpa: std.mem.Allocator, fixture: *Fixture, workload: main.Workload) !PipelineContext {
    var screen = try frontend.Screen.init(gpa, main.cols, main.rows);
    errdefer screen.deinit();
    var writer = std.Io.Writer.fixed(fixture.terminal_output);
    _ = try screen.flush(&writer);
    return .{
        .screen = screen,
        .payloads = fixture.payloads(workload),
        .output = fixture.terminal_output,
    };
}

pub fn deinit(self: *PipelineContext) void {
    self.screen.deinit();
}
