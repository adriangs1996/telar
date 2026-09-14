const core = @import("telar-core");
const client = @import("telar-client");
const Context = @import("Context.zig");
const BarContent = @import("BarContent.zig");
const MetricsLabel = @import("MetricsLabel.zig");
const tabs = @import("tabs.zig");
const bar_regions = @import("bar_regions.zig");
const SlotRow = @This();

context: *Context,
slots: *const [3]client.Slot,

/// Lays three configured slots left, center and right inside one chrome row.
/// The tabs slot keeps its minimum readable width; without tabs an empty slot
/// takes that role so the custom slots share the row.
/// Example: `try row.paint(regions.bottom);`
pub fn paint(row: SlotRow, area: core.Rect) !void {
    var desired: [3]u16 = @splat(0);
    for (row.slots, 0..) |*slot, index| {
        desired[index] = row.width(slot);
    }

    const regions = bar_regions.calculate(area, desired, row.priorityIndex());
    for (row.slots, regions) |*slot, region| {
        try row.paintSlot(region, slot);
    }
}

/// Measures one slot in cells for the caller's own layout.
/// Example: `const right_width = row.width(&layout.top_right);`
pub fn width(row: SlotRow, slot_value: *const client.Slot) u16 {
    return switch (slot_value.*) {
        .empty => 0,
        .tabs => tabs.width(row.context.projection.tabs),
        .metrics => MetricsLabel.init(row.context.projection.system_metrics).width(),
        .content => |*content| content.width(),
    };
}

/// Paints one slot clipped to the supplied area.
/// Example: `try row.paintSlot(right_area, &layout.top_right);`
pub fn paintSlot(row: SlotRow, area: core.Rect, value: *const client.Slot) !void {
    switch (value.*) {
        .empty => {},
        .tabs => try tabs.paint(row.context, area),
        .metrics => {
            const label = MetricsLabel.init(row.context.projection.system_metrics);
            try row.context.label(area, label.text());
        },
        .content => |*content| {
            const painter: BarContent = .{ .context = row.context, .content = content };
            try painter.paint(area);
        },
    }
}

fn priorityIndex(row: SlotRow) usize {
    for (row.slots, 0..) |slot, index| {
        if (slot == .tabs) {
            return index;
        }
    }
    for (row.slots, 0..) |slot, index| {
        if (slot == .empty) {
            return index;
        }
    }

    return 2;
}
