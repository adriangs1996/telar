const std = @import("std");
const gui = @import("telar-gui");

pub fn main() !void {
    var app = gui.Application.init(std.heap.c_allocator);
    defer app.deinit();

    try app.run("Telar");
}
