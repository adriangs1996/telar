const ScreenType = @import("telar-frontend").Screen;
const std = @import("std");
const main = @import("main.zig");
const CursorContext = @This();

screen: ScreenType,
output: []u8,

pub fn init(gpa: std.mem.Allocator, output: []u8) !CursorContext {
    var screen = try ScreenType.init(gpa, main.cols, main.rows);
    errdefer screen.deinit();
    var writer = std.Io.Writer.fixed(output);
    _ = try screen.flush(&writer);
    return .{ .screen = screen, .output = output };
}

pub fn deinit(context: *CursorContext) void {
    context.screen.deinit();
}
