//! Bounded proportional wrapping for a notification body, borrowed for a draw.
const std = @import("std");
const core = @import("telar-core");
const Canvas = @import("../Canvas.zig");
const Label = @import("../Label.zig");
const TextFit = @import("../TextFit.zig");
const Text = @This();

lines: [3][]const u8 = @splat(""),
count: usize = 0,
tail: [TextFit.max_bytes]u8 = undefined,
tail_len: ?usize = null,

/// Breaks at words or whole graphemes; only the final line uses an ellipsis.
/// Example: `try text.wrap(canvas, .{ .text = message, .width = width });`
pub fn wrap(text: *Text, canvas: *Canvas, input: @import("NotificationTextInput.zig")) !void {
    text.* = .{};
    var remaining = std.mem.trim(u8, input.text, " \t\r\n");
    while (remaining.len > 0 and text.count < text.lines.len) {
        const last = text.count + 1 == text.lines.len;
        const newline = std.mem.indexOfAny(u8, remaining, "\r\n") orelse remaining.len;
        var label: Label = .{ .text = remaining[0..newline], .face = .sans, .size = .body };
        if (last) {
            // Include a following paragraph in truncation rather than silently
            // hiding it when its first line happens to fit.
            if (newline < remaining.len) {
                const keep = @min(newline, text.tail.len - TextFit.ellipsis.len);
                var end = keep;
                while (end > 0 and remaining[end] & 0xc0 == 0x80) {
                    end -= 1;
                }

                @memcpy(text.tail[0..end], remaining[0..end]);
                @memcpy(text.tail[end..][0..TextFit.ellipsis.len], TextFit.ellipsis);
                label.text = text.tail[0 .. end + TextFit.ellipsis.len];
            }

            var buffer: [TextFit.max_bytes]u8 = undefined;
            const fitted = try (TextFit{ .canvas = canvas, .width = input.width }).fit(label, &buffer);
            if (fitted.ptr == buffer[0..].ptr or fitted.ptr == text.tail[0..].ptr) {
                std.mem.copyForwards(u8, &text.tail, fitted);
                text.tail_len = fitted.len;
            } else {
                text.lines[text.count] = fitted;
            }
            text.count += 1;
            break;
        }

        var end = newline;
        if (try canvas.measure(label) > input.width) {
            end = 0;
            var word_end: usize = 0;
            var iterator: core.GraphemeIterator = .{ .bytes = label.text };
            while (iterator.next()) |cluster| {
                const candidate = end + cluster.bytes.len;
                label.text = remaining[0..candidate];
                if (try canvas.measure(label) > input.width) {
                    break;
                }

                if (cluster.bytes.len == 1 and (cluster.bytes[0] == ' ' or cluster.bytes[0] == '\t')) {
                    word_end = end;
                }
                end = candidate;
            }

            if (word_end > 0) {
                end = word_end;
            }
            if (end == 0) {
                break;
            }
        }

        text.lines[text.count] = std.mem.trimEnd(u8, remaining[0..end], " \t");
        text.count += 1;
        remaining = std.mem.trimStart(u8, remaining[end..], " \t\r\n");
    }
}

/// Resolves the owned tail after the value has moved with its card.
/// Example: `const line = text.line(index);`
pub fn line(text: *const Text, index: usize) []const u8 {
    if (index + 1 == text.count) {
        if (text.tail_len) |len| {
            return text.tail[0..len];
        }
    }

    return text.lines[index];
}
