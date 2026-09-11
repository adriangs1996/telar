const CursorContext = @This();
const frontend = @import("telar-frontend");
const std = @import("std");
const source_namespace = @import("main.zig");
screen: frontend.term.Screen,
output: []u8,

fn init(gpa: std.mem.Allocator, output: []u8) !CursorContext {
    var screen = try frontend.term.Screen.init(gpa, source_namespace.cols, source_namespace.rows);
    errdefer screen.deinit();
    var writer = source_namespace.Io.Writer.fixed(output);
    _ = try screen.flush(&writer);
    return .{ .screen = screen, .output = output };
}

fn deinit(context: *CursorContext) void {
    context.screen.deinit();
}
