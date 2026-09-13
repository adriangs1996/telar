const client = @import("telar-client");
const core = @import("telar-core");
const Context = @import("Context.zig");
const TabLabel = @import("TabLabel.zig");
const Strip = @import("Strip.zig");
const PaneProgress = @import("PaneProgress.zig");

/// Keeps the active tab visible and exposes left-select/right-rename targets.
/// Example: `try tabs.paint(&context, bar);`
pub fn paint(context: *Context, area: core.Rect) !void {
    const collection = context.projection.tabs;
    if (area.isEmpty() or collection.count == 0) {
        return;
    }

    const first = firstVisible(collection, area.w);
    var strip: Strip = .{ .area = area };
    for (collection.items[first..collection.count], first..) |*slot, index| {
        const tab = if (slot.*) |*value| value else continue;
        if (index != first) {
            _ = strip.take(1);
        }

        if (strip.remaining() == 0) {
            break;
        }

        const label = TabLabel.init(tab, index);
        const target = strip.take(label.width());
        try context.button(.{
            .area = target,
            .intent = .{ .select_tab = tab.location.tab_id },
            .text = label.text(),
            .active = index == collection.active_index,
        });
        if (index == collection.active_index and tab.model.layout.count() == 1) {
            if (tab.model.focusedPaneConst()) |pane| {
                const progress: PaneProgress = .{ .context = context, .pane = pane };
                try progress.paint(target);
            }
        }
    }
}

/// Measures labels without shaping, allocation or borrowed retention.
/// Example: `const desired = tabs.width(projection.tabs);`
pub fn width(collection: *const client.TabsModel) u16 {
    var total: u16 = 0;
    for (collection.items[0..collection.count], 0..) |*slot, index| {
        const tab = if (slot.*) |*value| value else continue;
        total +|= TabLabel.init(tab, index).width();
        total +|= @intFromBool(index != 0);
    }

    return total;
}

fn firstVisible(collection: *const client.TabsModel, available: u16) usize {
    var first = collection.active_index;
    var used = @min(TabLabel.init(&collection.items[first].?, first).width(), available);
    while (first > 0) {
        const candidate = first - 1;
        const required = TabLabel.init(&collection.items[candidate].?, candidate).width() +| 1;
        if (required > available -| used) {
            break;
        }

        first = candidate;
        used += required;
    }

    return first;
}
