//! Native unified diffs share one measured flow with their visible text geometry.
const std = @import("std");
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const Label = @import("Label.zig");
const Line = @import("DiffLine.zig");
const Lines = @import("DiffLines.zig");
const Paint = @This();

canvas: *Canvas,
bounds: Rect,
viewport: Rect,
text: []const u8,
owner: ?@import("MessageLayoutOwner.zig") = null,
source_start: usize,
paint: bool,
y: f32 = 0,
digits: usize = 3,

/// Measures all lines but paints and retains selectable geometry only in view.
/// Example: `const height = try diff.layout();`
pub fn layout(widget: *Paint) !f32 {
    widget.y = widget.bounds.y;
    widget.digits = 3;
    var scan: Lines = .{ .text = widget.text };
    var maximum: u32 = 0;
    while (scan.next()) |line| {
        maximum = @max(maximum, @max(line.old orelse 0, line.new orelse 0));
    }

    while (maximum >= 1000) : (maximum /= 10) {
        widget.digits += 1;
    }

    const first = widget.canvas.quads.items().len;
    defer if (widget.paint) {
        widget.canvas.quads.clipFrom(first, widget.viewport);
    };
    var lines: Lines = .{ .text = widget.text };
    var started = false;
    while (lines.next()) |line| {
        if (line.kind == .file) {
            if (started) {
                widget.y += widget.canvas.chrome.px(14);
            }

            try widget.header(line, lines.counts());
            started = true;
            continue;
        }

        if (!started) {
            try widget.header(.{ .kind = .file, .text = "Changes" }, (Lines{ .text = widget.text }).counts());
            started = true;
        }

        if (line.kind == .hunk) {
            try widget.hunk(line);
        } else {
            try widget.code(line);
        }
    }

    return widget.y - widget.bounds.y + widget.canvas.chrome.px(10);
}

fn header(widget: *Paint, line: Line, counts: [2]u32) !void {
    const canvas = widget.canvas;
    const name = line.text[(if (std.mem.lastIndexOfScalar(u8, line.text, '/')) |at| at + 1 else 0)..];
    const has_path = !std.mem.eql(u8, line.text, name);
    const height = canvas.chrome.px(if (has_path or line.operation.len > 0) @as(f32, 60) else 40);
    defer widget.y += height;
    if (!widget.visible(height)) {
        return;
    }

    const area = widget.rowBounds(height);
    const inset = @min(canvas.chrome.px(12), area.width / 8);
    const badge_width = @min(canvas.chrome.px(100), area.width * 0.4);
    const title_width = @max(0, area.width - 2 * inset - badge_width);
    try canvas.fillRoundedAt(area, .{ .color = canvas.theme.palette.surface0, .radius = canvas.chrome.px(6) });
    try widget.fitted(.{ .x = area.x + inset, .y = area.y + canvas.chrome.px(5), .width = title_width, .height = canvas.chrome.px(28) }, .{ .text = name, .face = .sans, .size = .body, .bold = true, .color = canvas.theme.palette.text });
    var path_buffer: [1024]u8 = undefined;
    const path = shortPath(line.text, &path_buffer);
    var subtitle_buffer: [1152]u8 = undefined;
    const subtitle = if (!has_path) line.operation else if (line.operation.len == 0) path else std.fmt.bufPrint(&subtitle_buffer, "{s} · {s}", .{ line.operation, path }) catch path;
    try widget.fitted(.{ .x = area.x + inset, .y = area.y + canvas.chrome.px(32), .width = @max(0, area.width - 2 * inset), .height = canvas.chrome.px(20) }, .{ .text = subtitle, .face = .sans, .size = .small, .color = canvas.theme.palette.overlay1 });
    for (counts, 0..) |count, index| {
        var buffer: [16]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "{s}{d}", .{ if (index == 0) @as([]const u8, "+") else "-", count });
        const badge: Rect = .{ .x = area.x + area.width - inset - badge_width + @as(f32, @floatFromInt(index)) * badge_width / 2, .y = area.y + canvas.chrome.px(8), .width = badge_width / 2, .height = canvas.chrome.px(24) };
        try widget.fitted(badge, .{ .text = text, .face = .sans, .size = .small, .bold = true, .color = if (index == 0) canvas.theme.palette.green else canvas.theme.palette.red });
    }
}

fn hunk(widget: *Paint, line: Line) !void {
    const height = widget.canvas.chrome.px(28);
    defer widget.y += height;
    if (!widget.visible(height)) {
        return;
    }

    const canvas = widget.canvas;
    const area = widget.rowBounds(height);
    const first = canvas.quads.items().len;
    try canvas.fillAt(area, canvas.theme.palette.accent);
    canvas.quads.fadeFrom(first, 0.06);
    const inset = @min(canvas.chrome.px(12), area.width / 8);
    try widget.fitted(.{ .x = area.x + inset, .y = area.y, .width = @max(0, area.width - 2 * inset), .height = height }, .{ .text = line.text, .face = .sans, .size = .small, .color = canvas.theme.palette.subtext0 });
}

fn code(widget: *Paint, line: Line) !void {
    const canvas = widget.canvas;
    const cell: f32 = @floatFromInt(canvas.metrics.cell_width);
    const row = @max(canvas.chrome.px(22), @as(f32, @floatFromInt(canvas.metrics.cell_height)));
    const number_width = @as(f32, @floatFromInt(widget.digits)) * cell + canvas.chrome.px(12);
    const columns: usize = if (widget.bounds.width >= 2 * number_width + canvas.chrome.px(150)) 2 else if (widget.bounds.width >= number_width + canvas.chrome.px(100)) 1 else 0;
    const gutter = @min(widget.bounds.width / 2, @as(f32, @floatFromInt(columns)) * number_width + canvas.chrome.px(24));
    const padding = @min(canvas.chrome.px(10), widget.bounds.width / 12);
    const code_width = @max(1, widget.bounds.width - gutter - padding);
    var wrapped: @import("overlays/WrappedLines.zig") = .{ .text = line.text, .width = @intFromFloat(@min(65535, @max(1, @floor(code_width / cell)))) };
    var continuation = false;
    while (wrapped.next()) |text| {
        defer widget.y += row;
        const first_line = !continuation;
        continuation = true;
        if (!widget.visible(row)) {
            continue;
        }

        const area = widget.rowBounds(row);
        const palette = canvas.theme.palette;
        try canvas.fillAt(area, palette.surface_dim);
        try canvas.fillAt(.{ .x = area.x, .y = area.y, .width = gutter, .height = row }, palette.surface0);
        const ink = if (line.kind == .added) palette.green else palette.red;
        if (line.kind == .added or line.kind == .removed) {
            const first = canvas.quads.items().len;
            try canvas.fillAt(area, ink);
            canvas.quads.fadeFrom(first, 0.09);
            try canvas.fillAt(.{ .x = area.x, .y = area.y, .width = @min(canvas.chrome.px(2), area.width), .height = row }, ink);
        }

        if (first_line) {
            for (0..columns) |column| {
                const number = if (columns == 1) line.new orelse line.old else if (column == 0) line.old else line.new;
                if (number) |value| {
                    var buffer: [16]u8 = undefined;
                    const label: Label = .{ .text = try std.fmt.bufPrint(&buffer, "{d}", .{value}), .face = .sans, .size = .small, .color = palette.overlay1 };
                    const width = try canvas.measure(label);
                    const right = area.x + @as(f32, @floatFromInt(column + 1)) * number_width - canvas.chrome.px(6);
                    _ = try canvas.textAt(.{ .x = right - width, .y = area.y, .width = width, .height = row }, label);
                }
            }

            const marker: []const u8 = if (line.kind == .added) "+" else if (line.kind == .removed) "-" else "";
            _ = try canvas.textAt(.{ .x = area.x + gutter - canvas.chrome.px(18), .y = area.y, .width = canvas.chrome.px(16), .height = row }, .{ .text = marker, .color = ink });
        }

        try canvas.fillAt(.{ .x = area.x + gutter - 1, .y = area.y, .width = 1, .height = row }, palette.surface1);
        const text_area: Rect = .{ .x = area.x + gutter + padding / 2, .y = area.y, .width = @max(0, area.width - gutter - padding), .height = row };
        try widget.literal(text_area, text);
    }
}

fn literal(widget: *Paint, area: Rect, text: []const u8) !void {
    const canvas = widget.canvas;
    if (widget.owner) |owner| {
        if (canvas.widgets) |state| {
            if (state.thread_text) |store| {
                const geometry = store.maps.preparing();
                const offset = owner.source_offset + @as(u32, @intCast(@intFromPtr(text.ptr) - widget.source_start));
                if (try geometry.append(canvas, .{ .owner = owner, .offset = offset, .text = text, .bounds = area, .viewport = widget.viewport, .advance = 0, .face = .mono, .pixel_height = canvas.metrics.pixel_height })) |hit| {
                    try (@import("ThreadTextPaint.zig"){ .geometry = geometry, .fragment = hit }).draw(canvas);
                }
            }
        }
    }

    _ = try canvas.textAt(area, .{ .text = text, .color = canvas.theme.palette.text });
}

fn fitted(widget: *Paint, area: Rect, original: Label) !void {
    var buffer: [@import("TextFit.zig").max_bytes]u8 = undefined;
    var label = original;
    label.text = try (@import("TextFit.zig"){ .canvas = widget.canvas, .width = area.width }).fit(label, &buffer);
    _ = try widget.canvas.textAt(area, label);
}

fn visible(widget: Paint, height: f32) bool {
    return widget.paint and widget.y + height > widget.viewport.y and widget.y < widget.viewport.y + widget.viewport.height;
}

fn rowBounds(widget: Paint, height: f32) Rect {
    return .{ .x = widget.bounds.x, .y = widget.y, .width = widget.bounds.width, .height = height };
}

fn shortPath(path: []const u8, buffer: []u8) []const u8 {
    if (!std.mem.startsWith(u8, path, "/")) {
        return path;
    }

    var start = path.len;
    for (0..3) |_| {
        start = std.mem.lastIndexOfScalar(u8, path[0..start], '/') orelse return path;
    }

    return std.fmt.bufPrint(buffer, "…{s}", .{path[start..]}) catch path;
}
