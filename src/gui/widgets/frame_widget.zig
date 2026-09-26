//! The complete GUI frame. Native backends only see the quads these values draw.
const core = @import("telar-core");
const Notifications = @import("overlays/Notifications.zig");
const modal_widget = @import("overlays/modal_widget.zig");
const Canvas = @import("Canvas.zig");
const GenericWidgetList = @import("GenericWidgetList.zig").Type;
const TerminalPane = @import("TerminalPane.zig");
const HoveredLink = @import("HoveredLink.zig");
const TopBar = @import("TopBar.zig");
const StatusBar = @import("StatusBar.zig");
const Sidebar = @import("Sidebar.zig");
const WorkspaceRail = @import("WorkspaceRail.zig");
const RailTooltip = @import("RailTooltip.zig");
const BarOverlay = @import("BarOverlay.zig");
const PaneDecorations = @import("PaneDecorations.zig");
const ChromeFocus = @import("ChromeFocus.zig");
const NotificationCard = @import("overlays/NotificationCard.zig");

pub const capacity = core.max_panes_per_tab + 1 + 6 + 1 + Notifications.max_visible + 1;
pub const List = GenericWidgetList(Widget, capacity);

pub const Widget = union(enum) {
    terminal_pane: TerminalPane,
    link: HoveredLink,
    top_bar: TopBar,
    status: StatusBar,
    sidebar: Sidebar,
    rail: WorkspaceRail,
    rail_tooltip: RailTooltip,
    bar_overlay: BarOverlay,
    panes: PaneDecorations,
    chrome_focus: ChromeFocus,
    notification: NotificationCard,
    modal: modal_widget.Widget,

    /// Example: `try widget.draw(canvas);`
    pub fn draw(self: Widget, canvas: *Canvas) !void {
        switch (self) {
            inline else => |value| try value.draw(canvas),
        }
    }
};
