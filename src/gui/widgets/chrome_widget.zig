//! The permanent chrome's heterogeneous frame values. New Zig widgets join
//! this union without extending the Metal/Vulkan frame or native callbacks.
const Canvas = @import("../chrome/Canvas.zig");

pub const Widget = union(enum) {
    top_bar: @import("../chrome/TopBar.zig"),
    tabs: @import("../chrome/TabStrip.zig"),
    status: @import("../chrome/StatusBar.zig"),
    sidebar: @import("../chrome/SidebarView.zig"),
    panes: @import("../chrome/PaneDecorations.zig"),

    /// Example: `try widget.draw(canvas);`
    pub fn draw(widget: Widget, canvas: *Canvas) !void {
        switch (widget) {
            inline else => |value| try value.draw(canvas),
        }
    }
};
