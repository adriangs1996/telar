const std = @import("std");
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
            const icon_area = strip.take(2);
            if (segment.style.background) |background| {
                try canvas.fill(icon_area, color(canvas, background));
            }

            var icon_label = label;
            icon_label.text = icon.unicodeGlyph();
            try canvas.iconAt(canvas.rect(icon_area), icon_label);
        }

        const text_area = strip.take(textColumns(label.text));
        if (segment.style.background) |background| {
            try canvas.fill(text_area, color(canvas, background));
        }

        var text_strip: Strip = .{ .area = text_area };
        var iterator: core.GraphemeIterator = .{ .bytes = label.text };
        while (iterator.next()) |cluster| {
            const icon = isIcon(cluster.bytes);
            const area = text_strip.take(if (icon) 2 else cluster.width);
            var part = label;
            part.text = cluster.bytes;
            if (icon) {
                try canvas.iconAt(canvas.rect(area), part);
            } else {
                try canvas.text(area, part);
            }
        }
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

/// Measures GUI icon slots, including Nerd Font glyphs embedded in Lua text.
/// Example: `const columns = BarContent.columns(content);`
pub fn columns(content: *const client.Content) u16 {
    var count: u16 = 0;
    for (content.slice()) |segment| {
        if (segment.icon != null) {
            count +|= 2;
        }

        count +|= textColumns(content.text(segment));
    }

    return count;
}

fn textColumns(text: []const u8) u16 {
    var iterator: core.GraphemeIterator = .{ .bytes = text };
    var count: u16 = 0;
    while (iterator.next()) |cluster| {
        count +|= if (isIcon(cluster.bytes)) 2 else cluster.width;
    }

    return count;
}

// Nerd Fonts place their icons in Unicode's private-use ranges.
fn isIcon(text: []const u8) bool {
    var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();
    const codepoint = iterator.nextCodepoint() orelse return false;
    return (codepoint >= 0xe000 and codepoint <= 0xf8ff) or
        (codepoint >= 0xf0000 and codepoint <= 0xffffd) or
        (codepoint >= 0x100000 and codepoint <= 0x10fffd);
}

test "bar inline icons reserve two columns without changing text graphemes" {
    try std.testing.expectEqual(@as(u16, 13), textColumns("\u{f240} 100% | 52%"));
    try std.testing.expectEqual(@as(u16, 5), textColumns("e\u{301}界  "));
    try std.testing.expectEqual(@as(u16, 2), textColumns("\u{f03f0}"));
}
