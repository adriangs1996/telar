//! Allocation-free rendering for validated configured bar segments.

const bars = @import("../bars/root.zig");
const widget = @import("context.zig");
const ui = @import("../ui/root.zig");

pub fn render(context: *widget.Context, area: ui.Rect, input: Input) void {
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
            x += context.drawIcon(area, x, area.y, icon, style);
        }
        const remaining = area.x + area.w - x;
        x += context.buffer.writeTruncated(
            area,
            x,
            area.y,
            input.content.text(segment),
            remaining,
            style,
        );
    }
}

pub const Input = struct {
    content: *const bars.Content,
    alignment: bars.Alignment,
};

fn resolveStyle(context: *const widget.Context, configured: bars.Style) ui.Style {
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

fn resolveColor(context: *const widget.Context, color: bars.Color) ui.Color {
    return switch (color) {
        .value => |value| value,
        .palette => |role| switch (role) {
            inline else => |value| @field(context.palette, @tagName(value)),
        },
    };
}
