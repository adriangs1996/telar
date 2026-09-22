//! Tabs keep their navigation geometry. Workspace controls are a fallback
//! while the sidebar is hidden or the current context is not in its list.
const SidebarRegions = @import("SidebarRegions.zig");
const Bands = @import("Bands.zig");
const Context = @import("Context.zig");
const Rect = @import("../render/Rect.zig");
const WorkspaceIndicators = @import("WorkspaceIndicators.zig");
const TabStrip = @import("TabStrip.zig");
const Canvas = @import("Canvas.zig");
const Layout = @import("../layout/Layout.zig");
const LayoutItem = @import("../layout/Item.zig");
const PixelButton = @import("PixelButton.zig");
const ChangeReviewButton = @import("ChangeReviewButton.zig");
const TopBar = @This();

context: *const Context,
area: Rect,
sidebar_visible: bool,

/// Example: `try top_bar.draw(canvas);`
pub fn draw(widget: TopBar, canvas: *Canvas) !void {
    if (widget.area.width <= 0 or widget.area.height <= 0) {
        return;
    }

    const chrome = canvas.chrome;
    try canvas.panelAt(widget.area);

    var content = (Layout{
        .area = widget.area,
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
        if (widget.context.projection.model) |model| {
            if (model.focusedPaneConst()) |pane| {
                if (!model.layout.hasBorders()) {
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
                .fixed = @min(chrome.px(WorkspaceIndicators.preferredWidth(widget.context)), @floor(free / 2)),
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
        .context = widget.context,
        .area = children[0].bounds,
        .intent = .toggle_sidebar,
        .text = "\u{2261}",
        .active = widget.sidebar_visible,
        .radius = chrome.px(6),
        .inset = chrome.px(9),
    };
    try toggle.draw(canvas);

    const workspaces: WorkspaceIndicators = .{
        .context = widget.context,
        .area = children[1].bounds,
    };

    const active = widget.context.workspaceId();
    const listed = if (active) |id| widget.context.projection.workspaces.indexOf(id) != null else false;
    const regions = if (widget.context.sidebar_regions) |prepared| prepared.* else try SidebarRegions.resolve(canvas, Bands.resolve(canvas).sidebar, widget.context.projection.workspaces.count);
    if (!widget.sidebar_visible or !listed or regions.projects.height <= 0) {
        try workspaces.draw(canvas);
    }

    const tabs: TabStrip = .{
        .context = widget.context,
        .area = children[2].bounds,
    };

    try tabs.draw(canvas);
}
