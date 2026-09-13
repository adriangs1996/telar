const core = @import("telar-core");
const client = @import("telar-client");
const Context = @import("Context.zig");
const Strip = @import("Strip.zig");
const Label = @import("Label.zig");
const BarContent = @This();

context: *Context,
content: *const client.Content,

/// Draws validated Lua segments with the same palette roles as terminal cells.
/// Example: `try content.paint(area);`
pub fn paint(content: BarContent, area: core.Rect) !void {
    var strip: Strip = .{ .area = area };
    for (content.content.slice()) |segment| {
        if (strip.remaining() == 0) {
            break;
        }

        const label: Label = .{
            .text = content.content.text(segment),
            .color = if (segment.style.foreground) |value| content.color(value) else content.context.canvas.theme.palette.subtext0,
            .bold = segment.style.bold,
            .italic = segment.style.italic,
            .faint = segment.style.faint,
            .underline = segment.style.underline,
            .strikethrough = segment.style.strikethrough,
        };
        if (segment.icon) |icon| {
            const icon_area = strip.take(@max(1, core.measure(icon.unicodeGlyph())));
            if (segment.style.background) |background| {
                try content.context.canvas.fill(icon_area, content.color(background));
            }

            var icon_label = label;
            icon_label.text = icon.unicodeGlyph();
            try content.context.canvas.text(icon_area, icon_label);
        }

        const text_area = strip.take(core.measure(label.text));
        if (segment.style.background) |background| {
            try content.context.canvas.fill(text_area, content.color(background));
        }

        try content.context.canvas.text(text_area, label);
    }
}

fn color(content: BarContent, value: client.Color) core.Color {
    return switch (value) {
        .value => |literal| literal,
        .palette => |role| switch (role) {
            inline else => |field| @field(content.context.canvas.theme.palette, @tagName(field)),
        },
    };
}
