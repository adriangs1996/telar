//! Tabs keep their navigation geometry. Workspace controls are a fallback
//! while the sidebar is hidden or the current context is not in its list.
const data = @import("model");
const SidebarRegions = @import("SidebarRegions.zig");
const Bands = @import("Bands.zig");
const Context = @import("Context.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const WorkspaceIndicators = @import("WorkspaceIndicators.zig");
const TabStrip = @import("TabStrip.zig");
const Canvas = @import("Canvas.zig");
const Layout = gfx.Layout;
const LayoutItem = gfx.Item;
const PixelButton = @import("PixelButton.zig");
const ChangeReviewButton = @import("ChangeReviewButton.zig");
const TopBar = @This();

context: *const Context,
area: Rect,
sidebar_visible: bool,

/// Example: `try top_bar.draw(canvas);`
pub fn draw(self: TopBar, canvas: *Canvas) !void {
    if (self.area.width <= 0 or self.area.height <= 0) {
        return;
    }

    const chrome = canvas.chrome;
    try canvas.panelAt(self.area);

    var content = (Layout{
        .area = self.area,
        .padding = .{
            .left = chrome.px(8),
            .right = chrome.px(8),
        },
    }).content();

    const toggle_width = @min(content.width, chrome.px(30));
    const gap = @min(chrome.px(8), @max(0, content.width - toggle_width) / 2);
    const free = @max(0, content.width - toggle_width - 2 * gap);
    const control_height = @min(content.height, chrome.px(26));

    // The slot depends only on window geometry, so detach, split and focus do
    // not animate the tabs or move delivered workspace targets underneath input.
    if (content.width >= chrome.px(160)) {
        const projection = self.context.projection;
        if (projection.tab) |tab| {
            if (data.tab_layout.focusedPaneConst(projection.model, tab)) |pane| {
                if (!projection.model.tabs.layout[tab].hasBorders()) {
                    _ = try (ChangeReviewButton{ .area = content, .pane = pane, .placement = .top_bar }).draw(canvas);
                }
            }
        }
        content.width -= chrome.px(36);
    }

    var children = [_]LayoutItem{
        .{
            .width = .{
                .fixed = toggle_width,
            },
            .height = .{
                .fixed = control_height,
            },
        },
        .{
            .width = .{
                .fixed = @min(chrome.px(WorkspaceIndicators.preferredWidth(self.context)), @floor(free / 2)),
            },
            .height = .{
                .fixed = control_height,
            },
        },
        .{},
    };

    try (Layout{
        .area = content,
        .gap = gap,
        .cross_alignment = .center,
    }).resolve(&children);

    const toggle: PixelButton = .{
        .context = self.context,
        .area = children[0].bounds,
        .intent = .toggle_sidebar,
        .text = "\u{2261}",
        .active = self.sidebar_visible,
        .radius = chrome.px(6),
        .inset = chrome.px(9),
    };
    try toggle.draw(canvas);

    const workspaces: WorkspaceIndicators = .{
        .context = self.context,
        .area = children[1].bounds,
    };

    const active = self.context.workspaceId();
    const listed = if (active) |id| if (self.context.projection.workspaces.indexOf(id)) |index| index < self.context.projection.workspaces.project_count else false else false;
    const regions = if (self.context.sidebar_regions) |prepared| prepared.* else try SidebarRegions.resolve(canvas, Bands.resolve(canvas).sidebar, self.context.projection.workspaces.project_count);
    if (!self.sidebar_visible or !listed or regions.projects.height <= 0) {
        try workspaces.draw(canvas);
    }

    const tabs: TabStrip = .{
        .context = self.context,
        .area = children[2].bounds,
    };

    try tabs.draw(canvas);
}
