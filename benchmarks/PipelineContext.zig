const ScreenType = @import("telar-frontend").Screen;
const std = @import("std");
const Fixture = @import("Fixture.zig");
const main = @import("main.zig");
const PipelineContext = @This();

screen: ScreenType,
payloads: [2][]const u8,
output: []u8,

pub fn init(gpa: std.mem.Allocator, fixture: *Fixture, workload: main.Workload) !PipelineContext {
    var screen = try ScreenType.init(gpa, main.cols, main.rows);
    errdefer screen.deinit();
    var writer = std.Io.Writer.fixed(fixture.terminal_output);
    _ = try screen.flush(&writer);
    return .{
        .screen = screen,
        .payloads = fixture.payloads(workload),
        .output = fixture.terminal_output,
    };
}

pub fn deinit(context: *PipelineContext) void {
    context.screen.deinit();
}
