const LayoutType = @import("telar-client").WorkspaceLayout;
const RectType = @import("telar-core").Rect;
const main = @import("main.zig");
const LayoutContext = @This();

layout: LayoutType = .{},
area: RectType = .{ .w = main.cols, .h = main.rows },

pub fn init() !LayoutContext {
    var context: LayoutContext = .{};
    try context.layout.addRoot(@enumFromInt(1));
    try context.layout.split(.{ .existing_pane = @enumFromInt(1), .new_pane = @enumFromInt(2), .axis = .horizontal });
    try context.layout.split(.{ .existing_pane = @enumFromInt(1), .new_pane = @enumFromInt(3), .axis = .vertical });
    try context.layout.split(.{ .existing_pane = @enumFromInt(2), .new_pane = @enumFromInt(4), .axis = .vertical });
    return context;
}
