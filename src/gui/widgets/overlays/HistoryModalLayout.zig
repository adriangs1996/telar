//! Stable pixel layout: replacing a result page never moves the search field.
//! The panel takes most of the window above the status bar: the filters in
//! a header, the commands under it growing upward from the search field,
//! the field at the foot where the shell prompt was and the key hints
//! below it. The inspector shares the panel with the list; it never
//! resizes it.
const gfx = @import("gfx");
const Rect = gfx.Rect;
const Metrics = @import("HistoryModalMetrics.zig");
const Layout = @This();

/// Logical bounds of the panel. A window wider than `max_width` keeps
/// commands at a readable measure; the height follows the window.
pub const max_width: f32 = 1360;
pub const min_height: f32 = 640;
pub const height_share: f32 = 0.8;
/// The narrowest panel that shows the inspector beside the list.
pub const split_width: f32 = 900;
/// The share of a split panel the list keeps.
pub const list_share: f32 = 0.44;

viewport: Rect,
bounds: Rect,
/// The filter chips at the top; zero height in a compact panel.
header: Rect,
/// The command list; zero width while a narrow inspector replaces it.
results: Rect,
inspection: Rect,
search: Rect,
footer: Rect,
row_height: f32,
group_height: f32,
compact: bool,

/// The same layout determines native painting and inspector wrapping.
/// Example: `const layout = HistoryModalLayout.measure(metrics, inspecting);`
pub fn measure(metrics: Metrics, inspecting: bool) Layout {
    const px = metrics.chrome;
    const viewport = metrics.viewport;
    const margin = @min(px.px(28), @min(viewport.width, viewport.height) / 12);
    const width = @max(0, @min(px.px(max_width), viewport.width - margin * 2));
    const line_height = @max(px.rowHeight(.body), @as(f32, @floatFromInt(metrics.terminal.cell_height)));
    const row_height = @max(px.px(34), line_height + px.px(12));
    const group_height = @max(px.px(28), px.rowHeight(.small) + px.px(10));
    const header_height = @max(px.px(46), px.rowHeight(.small) + px.px(22));
    const search_height = @max(px.px(52), line_height + px.px(24));
    const footer_height = @max(px.px(36), px.rowHeight(.small) + px.px(14));
    const status_bar: f32 = @floatFromInt(px.status_bar);
    const available = viewport.height - status_bar - margin * 2;
    const height = @max(0, @min(available, @max(px.px(min_height), viewport.height * height_share)));
    const bounds: Rect = .{
        .x = @floor((viewport.width - width) / 2),
        .y = @floor(@max(0, @min(viewport.height - height, viewport.height - status_bar - margin - height))),
        .width = width,
        .height = height,
    };
    const compact = width < px.px(420) or height < px.px(260);
    var content = bounds;
    const footer = takeBottom(&content, footer_height);
    const search = takeBottom(&content, search_height);
    const header = takeTop(&content, if (compact) 0 else header_height);
    var list = content;
    var inspection: Rect = .{
        .x = content.x,
        .y = content.y,
        .width = 0,
        .height = 0,
    };
    if (inspecting) {
        inspection = content;
        if (width >= px.px(split_width)) {
            list.width = @floor(content.width * list_share);
            inspection.x = list.x + list.width;
            inspection.width = @max(0, content.width - list.width);
        } else {
            list.width = 0;
        }
    }

    return .{
        .viewport = viewport,
        .bounds = bounds,
        .header = header,
        .results = list,
        .inspection = inspection,
        .search = search,
        .footer = footer,
        .row_height = row_height,
        .group_height = group_height,
        .compact = compact,
    };
}

/// Moves paint and registered input geometry together during the entrance.
/// Example: `layout.offsetY(chrome.px(12) * (1 - reveal));`
pub fn offsetY(self: *Layout, offset: f32) void {
    inline for (.{ "bounds", "header", "results", "inspection", "search", "footer" }) |field| {
        @field(self, field).y += offset;
    }
}

/// The inspector's scrolling lines, above its action buttons.
/// Example: `const text = layout.inspectionContent(metrics);`
pub fn inspectionContent(self: Layout, metrics: Metrics) Rect {
    const inset = @min(metrics.chrome.px(18), @min(self.inspection.width, self.inspection.height) / 8);
    const actions = self.inspectionActions(metrics);
    return .{
        .x = self.inspection.x + inset,
        .y = self.inspection.y + inset,
        .width = @max(0, self.inspection.width - inset * 2),
        .height = @max(0, actions.y - self.inspection.y - inset * 2),
    };
}

/// The inspector's button row at its foot.
/// Example: `const buttons = layout.inspectionActions(metrics);`
pub fn inspectionActions(self: Layout, metrics: Metrics) Rect {
    const inset = @min(metrics.chrome.px(18), @min(self.inspection.width, self.inspection.height) / 8);
    const height = @min(@max(metrics.chrome.px(28), metrics.chrome.rowHeight(.body) + metrics.chrome.px(8)), @max(0, self.inspection.height - inset * 2));
    return .{
        .x = self.inspection.x + inset,
        .y = self.inspection.y + self.inspection.height - inset - height,
        .width = @max(0, self.inspection.width - inset * 2),
        .height = height,
    };
}

fn takeBottom(remaining: *Rect, height: f32) Rect {
    const taken = @min(remaining.height, height);
    remaining.height -= taken;
    return .{
        .x = remaining.x,
        .y = remaining.y + remaining.height,
        .width = remaining.width,
        .height = taken,
    };
}

fn takeTop(remaining: *Rect, height: f32) Rect {
    const taken = @min(remaining.height, height);
    const top: Rect = .{
        .x = remaining.x,
        .y = remaining.y,
        .width = remaining.width,
        .height = taken,
    };
    remaining.y += taken;
    remaining.height -= taken;
    return top;
}
