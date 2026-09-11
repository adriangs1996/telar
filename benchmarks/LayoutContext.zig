const LayoutContext = @This();
const frontend = @import("telar-frontend");
const core = @import("telar-core");
const source_namespace = @import("main.zig");
layout: frontend.layout.Layout = .{},
area: core.ui.Rect = .{ .w = source_namespace.cols, .h = source_namespace.rows },

fn init() !LayoutContext {
    var context: LayoutContext = .{};
    try context.layout.addRoot(@enumFromInt(1));
    try context.layout.split(.{ .existing_pane = @enumFromInt(1), .new_pane = @enumFromInt(2), .axis = .horizontal });
    try context.layout.split(.{ .existing_pane = @enumFromInt(1), .new_pane = @enumFromInt(3), .axis = .vertical });
    try context.layout.split(.{ .existing_pane = @enumFromInt(2), .new_pane = @enumFromInt(4), .axis = .vertical });
    return context;
}
