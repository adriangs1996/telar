//! Allocation-free rendering for validated configured bar segments.

const cellgrid = @import("cellgrid");
const data = @import("model");
const Context = @import("Context.zig");

pub fn render(context: *Context, area: cellgrid.Rect, input: BarContentInput) void {
    if (area.isEmpty()) {
        return;
    }

    const content_width = input.content.width();
    var x = switch (input.alignment) {
        .left => area.x,
        .center => area.x + (area.w - @min(area.w, content_width)) / 2,
        .right => area.x + area.w - @min(area.w, content_width),
    };
    for (input.content.slice()) |segment| {
        if (x >= area.x + area.w) {
            break;
        }

        const style = resolveStyle(context, segment.style);
        if (segment.icon) |icon| {
            x += context.drawIcon(.{ .area = area, .point = .{ .x = x, .y = area.y }, .icon = icon, .style = style });
        }
        const remaining = area.x + area.w - x;
        x += context.buffer.writeTruncated(area, .{ .point = .{ .x = x, .y = area.y }, .text = input.content.text(segment), .max_width = remaining, .style = style });
    }
}

fn resolveStyle(context: *const Context, configured: data.Style) cellgrid.Style {
    return .{
        .fg = if (configured.foreground) |color| resolveColor(context, color) else context.palette.subtext0,
        .bg = if (configured.background) |color| resolveColor(context, color) else context.palette.panel_bg,
        .flags = .{
            .bold = configured.bold,
            .italic = configured.italic,
            .faint = configured.faint,
            .underline = if (configured.underline) .single else .none,
            .strikethrough = configured.strikethrough,
        },
    };
}

fn resolveColor(context: *const Context, color: data.bar_values.Color) cellgrid.Color {
    return switch (color) {
        .value => |value| value,
        .palette => |role| switch (role) {
            inline else => |value| @field(context.palette, @tagName(value)),
        },
    };
}

const BarContentInput = struct {
    content: *const data.Content,
    alignment: data.bar_values.Alignment,
};
