//! One navigation row: a stable workspace region at the left and the active
//! workspace's tabs at the right. Sidebar geometry never moves either group.
const Context = @import("Context.zig");
const Rect = @import("../render/Rect.zig");
const WorkspacePills = @import("WorkspacePills.zig");
const TabStrip = @import("TabStrip.zig");
const Canvas = @import("Canvas.zig");
const Layout = @import("../layout/Layout.zig");
const LayoutItem = @import("../layout/Item.zig");
const TopBar = @This();

context: *Context,
area: Rect,
sidebar_visible: bool,

/// Example: `try top_bar.draw(canvas);`
pub fn draw(widget: TopBar, canvas: *Canvas) !void {
    if (widget.area.width <= 0 or widget.area.height <= 0) {
        return;
    }

    var context = widget.context.*;
    context.canvas = canvas;
    const chrome = canvas.chrome;
    try canvas.panelAt(widget.area);
    const content = (Layout{ .area = widget.area, .padding = .{ .left = chrome.px(8), .right = chrome.px(8) } }).content();
    const toggle_width = @min(content.width, chrome.px(30));
    const gap = @min(chrome.px(8), @max(0, content.width - toggle_width) / 2);
    const free = @max(0, content.width - toggle_width - 2 * gap);
    const control_height = @min(content.height, chrome.px(26));
    var children = [_]LayoutItem{
        .{ .width = .{ .fixed = toggle_width }, .height = .{ .fixed = control_height } },
        .{ .width = .{ .fixed = @min(chrome.px(WorkspacePills.preferred_width), @floor(free / 2)) }, .height = .{ .fixed = control_height } },
        .{},
    };
    try (Layout{ .area = content, .gap = gap, .cross_alignment = .center }).resolve(&children);
    try context.pill(.{
        .area = children[0].bounds,
        .intent = .toggle_sidebar,
        .text = "\u{2261}",
        .active = widget.sidebar_visible,
        .radius = chrome.px(6),
        .inset = chrome.px(9),
    });

    const workspaces: WorkspacePills = .{ .context = &context, .area = children[1].bounds };
    _ = try workspaces.paint();
    const tabs: TabStrip = .{ .context = &context, .area = children[2].bounds };
    try tabs.draw(canvas);
}
