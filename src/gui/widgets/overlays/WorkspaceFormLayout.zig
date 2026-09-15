//! Pixel layout for the new-context form, with bounded directory suggestions.
const client = @import("telar-client");
const Canvas = @import("../Canvas.zig");
const Rect = @import("../../render/Rect.zig");
const Layout = @import("../../layout/Layout.zig");
const Item = @import("../../layout/Item.zig");
const Form = @This();

viewport: Rect,
bounds: Rect,
header: Rect,
name: Rect,
directory: Rect,
suggestions: Rect,
footer: Rect,
rows: usize,
compact: bool,
field_height: f32,
label_height: f32,
small_height: f32,
heading_height: f32,
row_height: f32,

pub const max_rows = 4;

/// Size depends on GUI metrics and available pixels, not terminal columns.
/// Example: `const layout = try WorkspaceFormLayout.measure(canvas, projection);`
pub fn measure(canvas: *const Canvas, projection: *const client.Projection) !Form {
    const px = canvas.chrome;
    const fallback = canvas.rect(.{ .w = projection.host_size.cols, .h = projection.host_size.rows });
    const viewport: Rect = .{ .x = 0, .y = 0, .width = if (canvas.viewport[0] > 0) @floatFromInt(canvas.viewport[0]) else fallback.x + fallback.width, .height = if (canvas.viewport[1] > 0) @floatFromInt(canvas.viewport[1]) else fallback.y + fallback.height };
    const margin = @min(px.px(20), @min(viewport.width, viewport.height) / 12);
    const available = @max(0, viewport.height - margin * 2);
    const width = @max(0, @min(px.px(520), viewport.width - margin * 2));
    const label_height = px.rowHeight(.body);
    const small_height = px.rowHeight(.small);
    const heading_height = @ceil(@max(px.px(20), @as(f32, @floatFromInt(px.title))) * 1.3);
    const field_height = @max(px.px(36), label_height + px.px(14));
    const header_height = heading_height + px.px(4) + label_height;
    const name_height = label_height + field_height + small_height + px.px(12);
    const directory_height = label_height + field_height + px.px(6);
    const base_height = header_height + name_height + directory_height + field_height + px.px(108);
    const form = projection.prompt.?.mode.create_workspace;
    const confirmation_height = if (form.confirm_create) small_height * 2 + px.px(26) else 0;
    const row_height = @max(px.px(30), label_height + px.px(10));
    const list_header = small_height + px.px(18);
    const capacity: usize = @intFromFloat(@max(0, @floor((available - base_height - list_header) / row_height)));
    const rows = if (form.focus == .directory and !form.confirm_create) @min(max_rows, capacity, projection.path_completion.entries().len) else 0;
    const extra = if (rows > 0) list_header + @as(f32, @floatFromInt(rows)) * row_height else confirmation_height;
    const height = @min(available, base_height + extra);
    // Keep fields stationary when an asynchronous listing expands the dialog.
    const anchor_height = @min(available, base_height + @max(list_header + max_rows * row_height, confirmation_height));
    const bounds: Rect = .{ .x = @floor((viewport.width - width) / 2), .y = @floor((viewport.height - anchor_height) / 2), .width = width, .height = height };
    const compact = available < base_height or width < px.px(280);
    const padding = @min(px.px(if (compact) 10 else 24), @min(width, height) / 10);
    const gap = if (compact) px.px(6) else px.px(20);
    var sections = [_]Item{
        .{ .height = .{ .fixed = if (compact) @min(heading_height, height / 5) else header_height } },
        .{ .height = .{ .fixed = if (compact) 0 else name_height } },
        .{ .height = if (compact) .fill else .{ .fixed = directory_height + extra } },
        .{ .height = .{ .fixed = if (compact) @min(field_height, height / 5) else field_height } },
    };
    try (Layout{ .area = bounds, .direction = .column, .padding = .{ .left = padding, .right = padding, .top = padding, .bottom = padding }, .gap = if (compact) @min(gap, height / 20) else gap }).resolve(&sections);

    const directory = sections[2].bounds;
    const suggestions: Rect = .{ .x = directory.x, .y = directory.y + directory_height + list_header, .width = directory.width, .height = @as(f32, @floatFromInt(rows)) * row_height };
    return .{ .viewport = viewport, .bounds = bounds, .header = sections[0].bounds, .name = sections[1].bounds, .directory = directory, .suggestions = suggestions, .footer = sections[3].bounds, .rows = if (compact) 0 else rows, .compact = compact, .field_height = field_height, .label_height = label_height, .small_height = small_height, .heading_height = heading_height, .row_height = row_height };
}

/// Example: `const rect = layout.completionRow(index);`
pub fn completionRow(form: Form, index: usize) Rect {
    return .{ .x = form.suggestions.x, .y = form.suggestions.y + @as(f32, @floatFromInt(index)) * form.row_height, .width = form.suggestions.width, .height = form.row_height };
}
