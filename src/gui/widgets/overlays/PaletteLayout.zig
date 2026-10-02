//! Pixel geometry shared by command palettes and pick lists.
const Canvas = @import("../Canvas.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const Layout = @This();

pub const width_px = 640;
viewport: Rect,
bounds: Rect,
heading: Rect,
search: Rect,
tabs: Rect,
results: Rect,
footer: Rect,
row_height: f32,
agent_height: f32,
group_height: f32,

/// Keeps the search and footer fixed when a query changes the result count.
/// Example: `const layout = PaletteLayout.measure(canvas, .{ .pick_rows = 6 });`
pub fn measure(canvas: *const Canvas, options: struct { pick_rows: ?u16 = null, suggest: bool = false }) Layout {
    const px = canvas.chrome;
    const viewport: Rect = .{ .x = 0, .y = 0, .width = @floatFromInt(canvas.viewport[0]), .height = @floatFromInt(canvas.viewport[1]) };
    const margin = @min(px.px(24), @min(viewport.width, viewport.height) / 12);
    const width = @max(0, @min(px.px(width_px), viewport.width - margin * 2));
    const row_height = @max(px.px(38), px.rowHeight(.body) + px.px(16));
    const agent_height = @max(px.px(52), px.rowHeight(.body) + px.rowHeight(.small) + px.px(12));
    const group_height = @max(px.px(28), px.rowHeight(.small) + px.px(10));
    const nested = options.pick_rows != null or options.suggest;
    const heading_height = if (nested) @max(px.px(32), px.rowHeight(.small) + px.px(12)) else 0;
    const search_height = @max(px.px(60), px.rowHeight(.title) + px.px(24));
    const tabs_height = if (nested) 0 else @max(px.px(38), px.rowHeight(.small) + px.px(16));
    const footer_height = @max(px.px(40), px.rowHeight(.small) + px.px(16));
    const list_height = if (options.suggest) px.px(180) else if (options.pick_rows) |rows| row_height * @as(f32, @floatFromInt(@max(3, @min(rows, 8)))) + px.px(16) else row_height * 8 + px.px(22);
    const height = @max(0, @min(heading_height + search_height + tabs_height + list_height + footer_height, viewport.height - margin * 2));
    const top = @min(@max(margin, viewport.height * 0.11), @max(margin, viewport.height - margin - height));
    const bounds: Rect = .{ .x = @floor((viewport.width - width) / 2), .y = @floor(top), .width = width, .height = height };
    var rest = bounds;
    const heading = take(&rest, @min(heading_height, height / 6));
    const search = take(&rest, @min(search_height, rest.height / 2));
    const tabs = take(&rest, @min(tabs_height, rest.height / 4));
    const footer_size = @min(footer_height, rest.height / 3);
    const results = take(&rest, rest.height - footer_size);
    return .{ .viewport = viewport, .bounds = bounds, .heading = heading, .search = search, .tabs = tabs, .results = results, .footer = rest, .row_height = row_height, .agent_height = agent_height, .group_height = group_height };
}

/// Insets even tiny rectangles without negative extents.
/// Example: `const body = PaletteLayout.inset(layout.results, canvas.chrome.px(8));`
pub fn inset(rect: Rect, amount: f32) Rect {
    const x = @min(amount, rect.width / 2);
    const y = @min(amount, rect.height / 2);
    return .{ .x = rect.x + x, .y = rect.y + y, .width = @max(0, rect.width - x * 2), .height = @max(0, rect.height - y * 2) };
}

fn take(rest: *Rect, height: f32) Rect {
    const taken = @min(rest.height, height);
    const result: Rect = .{ .x = rest.x, .y = rest.y, .width = rest.width, .height = taken };
    rest.y += taken;
    rest.height -= taken;
    return result;
}
