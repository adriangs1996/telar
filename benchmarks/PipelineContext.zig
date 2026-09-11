const PipelineContext = @This();
const frontend = @import("telar-frontend");
const std = @import("std");
const Fixture = @import("Fixture.zig");
const source_namespace = @import("main.zig");
screen: frontend.term.Screen,
payloads: [2][]const u8,
output: []u8,

fn init(gpa: std.mem.Allocator, fixture: *Fixture, workload: source_namespace.Workload) !PipelineContext {
    var screen = try frontend.term.Screen.init(gpa, source_namespace.cols, source_namespace.rows);
    errdefer screen.deinit();
    var writer = source_namespace.Io.Writer.fixed(fixture.terminal_output);
    _ = try screen.flush(&writer);
    return .{
        .screen = screen,
        .payloads = fixture.payloads(workload),
        .output = fixture.terminal_output,
    };
}

fn deinit(context: *PipelineContext) void {
    context.screen.deinit();
}
