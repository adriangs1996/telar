//! One frame's sidebar geometry and semantic borrow. Scroll and ordering
//! remain in Sidebar when this view is discarded after drawing.
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const SidebarView = @This();

state: *@import("Sidebar.zig"),
context: *const Context,
area: @import("../render/Rect.zig"),

/// Example: `try sidebar_view.draw(canvas);`
pub fn draw(view: SidebarView, canvas: *Canvas) !void {
    var context = view.context.*;
    context.canvas = canvas;
    try view.state.paint(&context, view.area);
}
