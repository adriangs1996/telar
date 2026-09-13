const core = @import("telar-core");
const client = @import("telar-client");
const Context = @import("Context.zig");
const PaneLabel = @import("PaneLabel.zig");
const Strip = @import("Strip.zig");
const FullscreenStrip = @This();

context: *Context,
model: *const client.MultiplexerModel,

/// Fullscreen hides terminal leaves, but every pane remains directly reachable.
/// Example: `try strip.paint(fullscreen.outer.row(0));`
pub fn paint(fullscreen: FullscreenStrip, area: core.Rect) !void {
    if (area.isEmpty()) {
        return;
    }

    var identities: [core.max_panes_per_tab]core.PaneId = undefined;
    const panes = fullscreen.model.layout.orderedPanes(&identities);
    if (panes.len == 0) {
        return;
    }

    var labels: [core.max_panes_per_tab]PaneLabel = undefined;
    var total: u16 = @intCast(panes.len - 1);
    var focused: usize = 0;
    for (panes, 0..) |id, index| {
        const name = if (fullscreen.model.findConst(id)) |pane| pane.foregroundName() else "";
        labels[index] = .init(name, @intCast(index + 1));
        total +|= labels[index].width();
        if (fullscreen.model.layout.focused() == id) {
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

        try fullscreen.context.button(.{
            .area = strip.take(@min(labels[index].width(), limit)),
            .intent = .{ .focus_pane = id },
            .text = labels[index].text(),
            .active = index == focused,
        });
    }
}
