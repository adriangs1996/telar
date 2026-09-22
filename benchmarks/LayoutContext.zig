const data = @import("model");
const core = @import("telar-core");
const main = @import("main.zig");
const LayoutContext = @This();

layout: data.WorkspaceLayout = .{},
area: core.Rect = .{ .w = main.cols, .h = main.rows },

pub fn init() !LayoutContext {
    var context: LayoutContext = .{};
    try context.layout.addRoot(@enumFromInt(1));
    try context.layout.split(.{ .existing_pane = @enumFromInt(1), .new_pane = @enumFromInt(2), .axis = .horizontal });
    try context.layout.split(.{ .existing_pane = @enumFromInt(1), .new_pane = @enumFromInt(3), .axis = .vertical });
    try context.layout.split(.{ .existing_pane = @enumFromInt(2), .new_pane = @enumFromInt(4), .axis = .vertical });
    return context;
}
