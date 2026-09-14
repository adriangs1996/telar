const core = @import("telar-core");
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const Strip = @import("Strip.zig");
const Label = @import("Label.zig");
const BarContent = @This();

content: *const client.Content,
area: core.Rect,

/// Draws validated Lua segments with the same palette roles as terminal cells.
/// Example: `try content.draw(canvas);`
pub fn draw(content: BarContent, canvas: *Canvas) !void {
    var strip: Strip = .{ .area = content.area };
    for (content.content.slice()) |segment| {
        if (strip.remaining() == 0) {
            break;
        }

        const label: Label = .{
            .text = content.content.text(segment),
            .color = if (segment.style.foreground) |value| color(canvas, value) else canvas.theme.palette.subtext0,
            .bold = segment.style.bold,
            .italic = segment.style.italic,
            .faint = segment.style.faint,
            .underline = segment.style.underline,
            .strikethrough = segment.style.strikethrough,
        };
        if (segment.icon) |icon| {
            const icon_area = strip.take(@max(1, core.measure(icon.unicodeGlyph())));
            if (segment.style.background) |background| {
                try canvas.fill(icon_area, color(canvas, background));
            }

            var icon_label = label;
            icon_label.text = icon.unicodeGlyph();
            try canvas.text(icon_area, icon_label);
        }

        const text_area = strip.take(core.measure(label.text));
        if (segment.style.background) |background| {
            try canvas.fill(text_area, color(canvas, background));
        }

        try canvas.text(text_area, label);
    }
}

fn color(canvas: *const Canvas, value: client.Color) core.Color {
    return switch (value) {
        .value => |literal| literal,
        .palette => |role| switch (role) {
            inline else => |field| @field(canvas.theme.palette, @tagName(field)),
        },
    };
}
