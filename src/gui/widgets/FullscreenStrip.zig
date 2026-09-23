const data = @import("model");
const core = @import("telar-core");
const client = @import("telar-client");
const Context = @import("Context.zig");
const PaneLabel = @import("PaneLabel.zig");
const Strip = @import("Strip.zig");
const Canvas = @import("Canvas.zig");
const Button = @import("Button.zig");
const PaneProgress = @import("PaneProgress.zig");
const ChangeReviewButton = @import("ChangeReviewButton.zig");
const FullscreenStrip = @This();

context: *const Context,
model: *const data.ClientModel,
tab: usize,
area: core.Rect,

/// Fullscreen hides terminal leaves, but every pane remains directly reachable.
/// Example: `try strip.draw(canvas);`
pub fn draw(self: FullscreenStrip, canvas: *Canvas) !void {
    var area = self.area;
    if (area.isEmpty()) {
        return;
    }

    const model = self.model;
    const tab = self.tab;
    const layout = &model.tabs.layout[tab];
    if (data.tab_layout.focusedPaneConst(model, tab)) |pane| {
        const review_width = try (ChangeReviewButton{ .area = canvas.rect(area), .pane = pane, .placement = .fullscreen }).draw(canvas);
        const review_columns: u16 = @intFromFloat(@min(65535, @ceil(review_width / @as(f32, @floatFromInt(canvas.metrics.cell_width)))));
        area.w -|= review_columns;
        var progress: PaneProgress = .{ .pane = pane, .area = canvas.rect(area), .motions = self.context.progress };
        if (try progress.width(canvas) > progress.area.width / 2) {
            progress.compact = true;
        }

        const width = try progress.width(canvas);
        if (width > 0 and width + canvas.chrome.px(6) + 6 * @as(f32, @floatFromInt(canvas.metrics.cell_width)) <= progress.area.width) {
            try progress.draw(canvas);
            const columns: u16 = @intFromFloat(@min(65535, @ceil((width + canvas.chrome.px(6)) / @as(f32, @floatFromInt(canvas.metrics.cell_width)))));
            area.w -|= columns;
        }
    }

    var identities: [core.max_panes_per_tab]core.PaneId = undefined;
    const panes = layout.orderedPanes(&identities);
    if (panes.len == 0) {
        return;
    }

    var labels: [core.max_panes_per_tab]PaneLabel = undefined;
    var total: u16 = @intCast(panes.len - 1);
    var focused: usize = 0;
    for (panes, 0..) |id, index| {
        const name = if (model.panes.findInConst(model.tabs.location[tab].tab_id, id)) |pane| pane.foregroundName() else "";
        labels[index] = .init(name, @intCast(index + 1));
        total +|= labels[index].width();
        if (layout.focused() == id) {
            focused = index;
        }
    }

    const limit = if (total <= area.w) area.w else @max(6, (area.w -| @as(u16, @intCast(panes.len - 1))) / @as(u16, @intCast(panes.len)));
    var first = focused;
    var used = @min(labels[first].width(), @min(area.w, limit));
    while (first > 0) {
        const width = @min(labels[first - 1].width(), limit) +| 1;
        if (width > area.w -| used) {
            break;
        }

        first -= 1;
        used += width;
    }

    var strip: Strip = .{ .area = area };
    for (panes[first..], first..) |id, index| {
        if (index != first) {
            _ = strip.take(1);
        }

        if (strip.remaining() == 0) {
            break;
        }

        const button: Button = .{
            .context = self.context,
            .area = strip.take(@min(labels[index].width(), limit)),
            .intent = .{ .focus_pane = id },
            .text = labels[index].text(),
            .active = index == focused,
        };
        try button.draw(canvas);
    }
}
