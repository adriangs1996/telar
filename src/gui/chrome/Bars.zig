const core = @import("telar-core");
const client = @import("telar-client");
const Context = @import("Context.zig");
const Regions = @import("Regions.zig");
const WorkspaceList = @import("WorkspaceList.zig");
const BarContent = @import("BarContent.zig");
const MetricsLabel = @import("MetricsLabel.zig");
const ModeBar = @import("ModeBar.zig");
const tabs = @import("tabs.zig");
const bar_regions = @import("bar_regions.zig");
const Bars = @This();

context: *Context,
regions: Regions,

/// Composes workspace navigation, configured slots and transient input mode.
/// Example: `try bars.paint();`
pub fn paint(bars: Bars) !void {
    try bars.top();
    const area = bars.regions.bottom;
    try bars.context.canvas.fill(area, bars.context.canvas.theme.palette.panel_bg);
    if (bars.context.projection.status_mode != .normal) {
        const mode_bar: ModeBar = .{ .context = bars.context, .area = area };
        try mode_bar.paint();
        return;
    }

    const slots = &bars.context.projection.bar_state.layout.bottom;
    const tabs_index: usize = for (slots, 0..) |slot, index| {
        if (slot == .tabs) {
            break index;
        }
    } else 2;
    var desired: [3]u16 = @splat(0);
    for (slots, 0..) |*slot, index| {
        desired[index] = bars.width(slot);
    }

    const regions = bar_regions.calculate(area, desired, tabs_index);
    for (slots, regions) |*slot, region| {
        try bars.paintSlot(region, slot);
    }
}

fn top(bars: Bars) !void {
    const area = bars.regions.top;
    if (area.isEmpty()) {
        return;
    }

    const palette = bars.context.canvas.theme.palette;
    const projection = bars.context.projection;
    try bars.context.canvas.fill(area, palette.panel_bg);
    const logo, const remainder = area.splitLeft(4);
    try bars.context.button(.{ .area = logo, .intent = .toggle_sidebar, .text = " ≡ ", .active = !bars.regions.sidebar.isEmpty() });
    const badge_width: u16 = if (projection.proxy_tls_active or projection.proxy_system_trusted) @min(remainder.w, 5) else 0;
    const right = &projection.bar_state.layout.top_right;
    const right_width = @min(bars.width(right), remainder.w -| badge_width -| 4);
    const list_area, const trailing = remainder.splitLeft(remainder.w - badge_width - right_width);
    const right_area, const badge = trailing.splitLeft(right_width);
    const list: WorkspaceList = .{ .context = bars.context, .area = list_area };
    try list.paint();
    try bars.paintSlot(right_area, right);
    if (badge_width != 0) {
        try bars.context.canvas.text(badge, .{
            .text = " TLS ",
            .color = if (!projection.proxy_tls_active) palette.yellow else if (projection.proxy_tls_scope == .wildcard) palette.red else palette.peach,
            .bold = true,
        });
    }
}

fn width(bars: Bars, slot_value: *const client.Slot) u16 {
    return switch (slot_value.*) {
        .empty => 0,
        .tabs => tabs.width(bars.context.projection.tabs),
        .metrics => MetricsLabel.init(bars.context.projection.system_metrics).width(),
        .content => |*content| content.width(),
    };
}

fn paintSlot(bars: Bars, area: core.Rect, value: *const client.Slot) !void {
    switch (value.*) {
        .empty => {},
        .tabs => try tabs.paint(bars.context, area),
        .metrics => {
            const label = MetricsLabel.init(bars.context.projection.system_metrics);
            try bars.context.label(area, label.text());
        },
        .content => |*content| {
            const painter: BarContent = .{ .context = bars.context, .content = content };
            try painter.paint(area);
        },
    }
}
