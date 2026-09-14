//! The complete GUI frame. Native backends only see the quads these values draw.
const Canvas = @import("../chrome/Canvas.zig");
const GenericWidgetList = @import("GenericWidgetList.zig").Type;

pub const capacity = @import("telar-core").max_panes_per_tab + 1 + 4 + 1 + @import("../overlays/Notifications.zig").max_visible + 1;
pub const List = GenericWidgetList(Widget, capacity);

pub const Widget = union(enum) {
    terminal_pane: @import("TerminalPane.zig"),
    thread: @import("ThreadPane.zig"),
    link: @import("HoveredLink.zig"),
    top_bar: @import("../chrome/TopBar.zig"),
    status: @import("../chrome/StatusBar.zig"),
    sidebar: @import("../chrome/SidebarView.zig"),
    panes: @import("../chrome/PaneDecorations.zig"),
    chrome_focus: @import("ChromeFocus.zig"),
    notification: @import("../overlays/NotificationCard.zig"),
    modal: @import("../overlays/modal_widget.zig").Widget,

    /// Example: `try widget.draw(canvas);`
    pub fn draw(widget: Widget, canvas: *Canvas) !void {
        switch (widget) {
            inline else => |value| try value.draw(canvas),
        }
    }
};
