const core = @import("telar-core");
const client = @import("telar-client");
const Context = @import("Context.zig");
const PaneLabel = @import("PaneLabel.zig");
const PaneProgress = @import("PaneProgress.zig");
const FullscreenStrip = @import("FullscreenStrip.zig");
const PaneDecorations = @This();

context: *Context,

/// Uses the same immutable pane geometry as terminal painting and input routing.
/// Example: `try decorations.paint();`
pub fn paint(decorations: PaneDecorations) !void {
    const context = decorations.context;
    const model = context.projection.model orelse return;
    if (!model.layout.hasBorders()) {
        return;
    }

    var layout: client.LayoutSnapshot = .{};
    model.layout.snapshot(context.projection.geometry.area, &layout);
    for (layout.views()) |view| {
        const pane = model.findConst(view.pane_id) orelse continue;
        try decorations.border(view);
        const title = view.outer.row(0);
        if (model.layout.isFullscreen()) {
            const strip: FullscreenStrip = .{ .context = context, .model = model };
            try strip.paint(title);
        } else {
            const label = PaneLabel.init(pane.foregroundName(), view.display_index);
            var target = title;
            target.w = @min(target.w, label.width());
            try context.button(.{ .area = target, .intent = .{ .focus_pane = view.pane_id }, .text = label.text(), .active = view.focused });
        }

        const progress: PaneProgress = .{ .context = context, .pane = pane };
        try progress.paint(view.outer);
    }
}

fn border(decorations: PaneDecorations, view: client.LayoutView) !void {
    const context = decorations.context;
    const outer = view.outer;
    const content = view.content;
    const bands = [_]core.Rect{
        .{ .x = outer.x, .y = outer.y, .w = outer.w, .h = content.y -| outer.y },
        .{ .x = outer.x, .y = content.y + content.h, .w = outer.w, .h = (outer.y + outer.h) -| (content.y + content.h) },
        .{ .x = outer.x, .y = content.y, .w = content.x -| outer.x, .h = content.h },
        .{ .x = content.x + content.w, .y = content.y, .w = (outer.x + outer.w) -| (content.x + content.w), .h = content.h },
    };
    for (bands) |band| {
        try context.canvas.fill(band, context.canvas.theme.palette.panel_bg);
        try context.hits.add(.{ .area = band, .action = .{ .intent = .{ .focus_pane = view.pane_id } } });
    }

    try context.canvas.border(outer, if (view.focused) context.canvas.theme.palette.accent else context.canvas.theme.palette.overlay0);
}
