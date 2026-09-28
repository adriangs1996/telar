//! Stable pixel layout: replacing a result page never moves the search field.
//! The panel sits at the bottom of the window above the status bar, the
//! field at its foot where the shell prompt was, the chips above the field
//! and the newest command right above the chips.
const gfx = @import("gfx");
const Rect = gfx.Rect;
const Metrics = @import("HistoryModalMetrics.zig");
const Layout = @This();

/// Rows the list is sized for; a smaller window shows fewer.
pub const visible_rows: f32 = 14;

viewport: Rect,
bounds: Rect,
/// The command list; zero width while a narrow inspector replaces it.
results: Rect,
inspection: Rect,
chips: Rect,
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
    const margin = @min(px.px(24), @min(viewport.width, viewport.height) / 12);
    const width = @max(0, @min(px.px(if (inspecting) 1120 else 760), viewport.width - margin * 2));
    const line_height = @max(px.rowHeight(.body), @as(f32, @floatFromInt(metrics.terminal.cell_height)));
    const row_height = @max(px.px(34), line_height + px.px(8));
    const group_height = @max(px.px(24), px.rowHeight(.small) + px.px(6));
    const chips_height = @max(px.px(40), px.rowHeight(.small) + px.px(18));
    const search_height = @max(px.px(48), line_height + px.px(18));
    const footer_height = @max(px.px(36), px.rowHeight(.small) + px.px(14));
    const status_bar: f32 = @floatFromInt(px.status_bar);
    const wanted = row_height * visible_rows + px.px(8) + chips_height + search_height + footer_height;
    const height = @max(0, @min(wanted, viewport.height - status_bar - margin * 2));
    const bounds: Rect = .{
        .x = @floor((viewport.width - width) / 2),
        .y = @floor(@max(0, @min(viewport.height - height, viewport.height - status_bar - margin - height))),
        .width = width,
        .height = height,
    };
    const compact = width < px.px(420) or height < px.px(240);
    var content = bounds;
    const footer = takeBottom(&content, footer_height);
    const search = takeBottom(&content, search_height);
    const chips = takeBottom(&content, if (compact) 0 else chips_height);
    var list = content;
    var inspection: Rect = .{
        .x = content.x,
        .y = content.y,
        .width = 0,
        .height = 0,
    };
    if (inspecting) {
        inspection = content;
        if (width >= px.px(1000)) {
            list.width = @floor(content.width * 0.56);
            inspection.x = list.x + list.width;
            inspection.width = @max(0, content.width - list.width);
        } else {
            list.width = 0;
        }
    }

    return .{
        .viewport = viewport,
        .bounds = bounds,
        .results = list,
        .inspection = inspection,
        .chips = chips,
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
    inline for (.{ "bounds", "results", "inspection", "chips", "search", "footer" }) |field| {
        @field(self, field).y += offset;
    }
}

/// The inspector's scrolling lines, above its action buttons.
/// Example: `const text = layout.inspectionContent(metrics);`
pub fn inspectionContent(self: Layout, metrics: Metrics) Rect {
    const inset = @min(metrics.chrome.px(14), @min(self.inspection.width, self.inspection.height) / 8);
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
    const inset = @min(metrics.chrome.px(14), @min(self.inspection.width, self.inspection.height) / 8);
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
