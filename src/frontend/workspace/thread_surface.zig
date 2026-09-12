//! Cell painting of a thread surface: the agent header, the transcript area
//! and the composer line. The GUI paints the same projection natively.

const std = @import("std");
const BufferType = @import("telar-core").Buffer;
const RectType = @import("telar-core").Rect;
const StyleType = @import("telar-core").Style;
const measure_module = @import("telar-core").measure;
const ThreadSurfaceInput = @import("ThreadSurfaceInput.zig");

/// Paints one thread surface into `area`, clearing it first so stale terminal
/// cells never show through.
///
/// ```zig
/// thread_surface.paint(target, view.content, .{ .view = thread, .palette = palette });
/// ```
pub fn paint(buffer: *BufferType, area: RectType, input: ThreadSurfaceInput) void {
    if (area.w == 0 or area.h == 0) {
        return;
    }

    const base: StyleType = .{ .fg = input.palette.text, .bg = input.palette.surface_dim };
    buffer.fill(area, .{ .style = base });
    const header, const rest = area.splitTop(1);
    paintHeader(buffer, header, input);
    if (rest.h == 0) {
        return;
    }

    const body, const composer = rest.splitBottom(1);
    paintBody(buffer, body, input);
    paintComposer(buffer, composer, input);
}

fn paintHeader(buffer: *BufferType, row: RectType, input: ThreadSurfaceInput) void {
    var storage: [128]u8 = undefined;
    const text = if (input.view.agent) |agent|
        std.fmt.bufPrint(&storage, " {s} {s} · {s}", .{ agent.iconGlyph(), agent.displayName(), @tagName(agent.status) }) catch storage[0..0]
    else
        " no agent in this pane";
    _ = buffer.writeTruncated(row, .{
        .point = .{ .x = row.x, .y = row.y },
        .text = text,
        .max_width = row.w,
        .style = .{ .fg = input.palette.accent, .bg = input.palette.surface0, .flags = .{ .bold = true } },
    });
}

fn paintBody(buffer: *BufferType, body: RectType, input: ThreadSurfaceInput) void {
    if (body.h == 0) {
        return;
    }

    const label = "transcript index pending";
    const width = @min(body.w, measure_module(label));
    _ = buffer.writeTruncated(body, .{
        .point = .{ .x = body.x + (body.w - width) / 2, .y = body.y + body.h / 2 },
        .text = label,
        .max_width = width,
        .style = .{ .fg = input.palette.subtext0, .bg = input.palette.surface_dim },
    });
}

fn paintComposer(buffer: *BufferType, row: RectType, input: ThreadSurfaceInput) void {
    const draft = input.view.composer;
    const empty = draft.len == 0;
    var storage: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&storage, "> {s}", .{if (empty) "write to the agent" else draft}) catch "> …";
    _ = buffer.writeTruncated(row, .{
        .point = .{ .x = row.x, .y = row.y },
        .text = text,
        .max_width = row.w,
        .style = .{ .fg = if (empty) input.palette.overlay1 else input.palette.text, .bg = input.palette.surface0 },
    });
}

test "thread surface paints header, body and composer inside its area" {
    const PaletteType = @import("telar-client").Palette;
    const theme_support = @import("telar-client").theme_support;
    var buffer = try BufferType.init(std.testing.allocator, 30, 6);
    defer buffer.deinit();
    buffer.clear(.{});
    const palette: PaletteType = theme_support.default_theme.palette;
    const area: RectType = .{ .x = 1, .y = 1, .w = 26, .h = 4 };

    paint(&buffer, area, .{ .view = .{ .pane_id = @enumFromInt(1), .agent = null, .composer = "hi" }, .palette = &palette });

    try std.testing.expectEqualStrings("n", buffer.at(2, 1).?.text());
    try std.testing.expectEqualStrings(">", buffer.at(1, 4).?.text());
    try std.testing.expectEqualStrings("h", buffer.at(3, 4).?.text());
    try std.testing.expectEqualStrings(" ", buffer.at(0, 0).?.text());
    try std.testing.expectEqualStrings(" ", buffer.at(27, 4).?.text());
}
