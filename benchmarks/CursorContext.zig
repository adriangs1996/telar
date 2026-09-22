const frontend = @import("telar-frontend");
const std = @import("std");
const main = @import("main.zig");
const CursorContext = @This();

screen: frontend.Screen,
output: []u8,

pub fn init(gpa: std.mem.Allocator, output: []u8) !CursorContext {
    var screen = try frontend.Screen.init(gpa, main.cols, main.rows);
    errdefer screen.deinit();
    var writer = std.Io.Writer.fixed(output);
    _ = try screen.flush(&writer);
    return .{ .screen = screen, .output = output };
}

pub fn deinit(context: *CursorContext) void {
    context.screen.deinit();
}
