//! Stable pixel layout: replacing a result page never moves the search field.
const Rect = @import("../../render/Rect.zig");
const Metrics = @import("HistoryModalMetrics.zig");
const Layout = @This();

viewport: Rect,
bounds: Rect,
header: Rect,
search: Rect,
scope: Rect,
summary: Rect,
results: Rect,
inspection: Rect,
detail: Rect,
footer: Rect,
row_height: f32,
rows: u16,
compact: bool,

/// The same layout determines native painting and inspector wrapping.
/// Example: `const layout = HistoryModalLayout.measure(metrics, inspecting);`
pub fn measure(metrics: Metrics, inspecting: bool) Layout {
    const px = metrics.chrome;
    const viewport = metrics.viewport;
    const margin = @min(px.px(24), @min(viewport.width, viewport.height) / 12);
    const width = @max(0, @min(px.px(if (inspecting) 1040 else 800), viewport.width - margin * 2));
    const line_height = @max(px.rowHeight(.body), @as(f32, @floatFromInt(metrics.terminal.cell_height)));
    const row_height = @max(px.px(48), line_height + px.rowHeight(.small) + px.px(12));
    const height = @max(0, @min(px.px(198) + row_height * 8, viewport.height - margin * 2));
    const bounds: Rect = .{ .x = @floor((viewport.width - width) / 2), .y = @floor((viewport.height - height) / 2), .width = width, .height = height };
    const padding = @min(px.px(20), @min(width, height) / 10);
    const compact = width < px.px(420) or height < px.px(300);
    const gap = @min(px.px(12), height / 30);
    var content: Rect = .{ .x = bounds.x + padding, .y = bounds.y + padding, .width = @max(0, width - padding * 2), .height = @max(0, height - padding * 2) };
    const header = take(&content, @max(px.px(30), px.rowHeight(.title)), gap);
    var search = take(&content, @max(px.px(38), px.rowHeight(.body) + px.px(16)), gap);
    const scope_width = @min(px.px(136), search.width * 0.35);
    const scope: Rect = .{ .x = search.x + search.width - scope_width, .y = search.y, .width = scope_width, .height = search.height };
    search.width = @max(0, search.width - scope_width - gap);
    const summary = take(&content, px.rowHeight(.small), gap / 2);
    const footer_height = @min(@max(px.px(32), px.rowHeight(.body) + px.px(10)), content.height);
    const detail_height = if (compact) 0 else @min(px.rowHeight(.small), @max(0, content.height - footer_height - gap * 2));
    const results = take(&content, @max(0, content.height - footer_height - detail_height - gap * 2), gap);
    const detail = take(&content, detail_height, gap);
    const footer = take(&content, footer_height, 0);
    var list = results;
    var inspection: Rect = .{ .x = results.x, .y = results.y, .width = 0, .height = 0 };
    if (inspecting) {
        inspection = results;
        if (width >= px.px(760)) {
            list.width = @floor((results.width - gap) * 0.43);
            inspection.x = list.x + list.width + gap;
            inspection.width = @max(0, results.width - list.width - gap);
        } else {
            list.width = 0;
        }
    }

    return .{ .viewport = viewport, .bounds = bounds, .header = header, .search = search, .scope = scope, .summary = summary, .results = list, .inspection = inspection, .detail = detail, .footer = footer, .row_height = row_height, .rows = @intFromFloat(@min(16, @floor(list.height / row_height))), .compact = compact };
}

/// Moves paint and registered input geometry together during the entrance.
/// Example: `layout.offsetY(chrome.px(12) * (1 - reveal));`
pub fn offsetY(layout: *Layout, offset: f32) void {
    inline for (.{ "bounds", "header", "search", "scope", "summary", "results", "inspection", "detail", "footer" }) |field| {
        @field(layout, field).y += offset;
    }
}

/// Newest stays at the bottom, matching the existing history arrow navigation.
/// Example: `const row = layout.row(offset);`
pub fn row(layout: Layout, offset: u16) Rect {
    return .{ .x = layout.results.x, .y = layout.results.y + layout.results.height - @as(f32, @floatFromInt(offset + 1)) * layout.row_height, .width = layout.results.width, .height = layout.row_height };
}

/// Example: `const text = layout.inspectionContent(metrics);`
pub fn inspectionContent(layout: Layout, metrics: Metrics) Rect {
    const inset = @min(metrics.chrome.px(12), @min(layout.inspection.width, layout.inspection.height) / 8);
    return .{ .x = layout.inspection.x + inset, .y = layout.inspection.y + inset, .width = @max(0, layout.inspection.width - inset * 2), .height = @max(0, layout.inspection.height - inset * 2) };
}

fn take(remaining: *Rect, height: f32, gap: f32) Rect {
    const result: Rect = .{ .x = remaining.x, .y = remaining.y, .width = remaining.width, .height = @min(remaining.height, height) };
    const advance = @min(remaining.height, result.height + gap);
    remaining.y += advance;
    remaining.height -= advance;
    return result;
}
