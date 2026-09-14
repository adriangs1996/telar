//! The 38 px band across the window: sidebar toggle, workspace pills, the
//! selected workspace's location, the configured right slot and the TLS
//! badge. Painted in `panel_bg` with no line under it; the tab strip below
//! continues the same surface.
const core = @import("telar-core");
const client = @import("telar-client");
const Context = @import("Context.zig");
const Bands = @import("Bands.zig");
const Rect = @import("../render/Rect.zig");
const WorkspacePills = @import("WorkspacePills.zig");
const Location = @import("Location.zig");
const SlotPainter = @import("SlotPainter.zig");
const TopBar = @This();

context: *Context,
bands: Bands,
home: []const u8,
sidebar_visible: bool,

/// Example: `try top_bar.paint();`
pub fn paint(bar: TopBar) !void {
    const area = bar.bands.top_bar;
    if (area.width <= 0 or area.height <= 0) {
        return;
    }

    const canvas = bar.context.canvas;
    const palette = canvas.theme.palette;
    const chrome = canvas.chrome;
    try canvas.fillAt(area, palette.panel_bg);
    const margin = chrome.px(8);
    const gap = chrome.px(8);
    const control_height = @min(area.height, chrome.px(24));
    const row: Rect = .{ .x = area.x + margin, .y = area.y + @floor((area.height - control_height) / 2), .width = @max(0, area.width - 2 * margin), .height = control_height };
    var left = row.x;
    const toggle_width = @min(row.width, chrome.px(30));
    try bar.context.pill(.{
        .area = .{ .x = left, .y = row.y, .width = toggle_width, .height = row.height },
        .intent = .toggle_sidebar,
        .text = "\u{2261}",
        .active = bar.sidebar_visible,
        .radius = chrome.px(6),
        .inset = chrome.px(9),
    });
    left += toggle_width + gap;

    var right = row.x + row.width;
    const projection = bar.context.projection;
    if (projection.proxy_tls_active or projection.proxy_system_trusted) {
        const badge = " TLS ";
        const badge_width = @min(try canvas.measure(.{ .text = badge }), @max(0, right - left));
        right -= badge_width;
        _ = try canvas.textAt(.{ .x = right, .y = row.y, .width = badge_width, .height = row.height }, .{
            .text = badge,
            .color = if (!projection.proxy_tls_active) palette.yellow else if (projection.proxy_tls_scope == .wildcard) palette.red else palette.peach,
            .bold = true,
        });
    }

    const top_right = &projection.bar_state.layout.top_right;
    const slot: SlotPainter = .{ .context = bar.context };
    const slot_width = @min(slot.pixelWidth(top_right), @max(0, right - left));
    if (slot_width > 0) {
        right -= slot_width;
        try slot.paintIn(.{ .x = right, .y = row.y, .width = slot_width, .height = row.height }, top_right);
    }

    // Pills claim at most half of the free width so the location stays readable.
    const free = @max(0, right - left);
    const pills: WorkspacePills = .{ .context = bar.context, .area = .{ .x = left, .y = row.y, .width = @floor(free / 2), .height = row.height } };
    left += try pills.paint();
    const location: Location = .{ .context = bar.context, .home = bar.home };
    right -= gap;
    if (right > left + gap) {
        _ = try location.paint(.{ .x = left + gap, .y = row.y, .width = right - left - gap, .height = row.height });
    }
}
