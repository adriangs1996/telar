//! OSC 22 mouse-pointer shapes emitted by the host presentation path.

const std = @import("std");
const core = @import("telar-core");

pub const Shape = core.schema.frame.PointerShape;
pub const reset_sequence = sequence(.default);

/// Encodes one bounded pointer shape without allocating.
///
/// ```zig
/// try writer.writeAll(sequence(.pointer));
/// ```
pub fn sequence(shape: Shape) []const u8 {
    return switch (shape) {
        inline else => |value| comptime shapeSequence(value),
    };
}

fn shapeSequence(comptime shape: Shape) []const u8 {
    const tag = @tagName(shape);
    var name: [tag.len]u8 = undefined;

    for (tag, 0..) |byte, index| {
        name[index] = if (byte == '_') '-' else byte;
    }

    return "\x1b]22;" ++ name ++ "\x1b\\";
}

test "every wire pointer shape has a bounded CSS sequence" {
    inline for (std.meta.tags(Shape)) |shape| {
        const encoded = sequence(shape);
        try std.testing.expect(std.mem.startsWith(u8, encoded, "\x1b]22;"));
        try std.testing.expect(std.mem.endsWith(u8, encoded, "\x1b\\"));
        try std.testing.expect(encoded.len <= 20);

        for (encoded[5 .. encoded.len - 2]) |byte| {
            try std.testing.expect(std.ascii.isLower(byte) or byte == '-');
        }
    }

    try std.testing.expectEqualStrings("\x1b]22;default\x1b\\", reset_sequence);
    try std.testing.expectEqualStrings("\x1b]22;pointer\x1b\\", sequence(.pointer));
    try std.testing.expectEqualStrings("\x1b]22;ew-resize\x1b\\", sequence(.ew_resize));
    try std.testing.expectEqualStrings("\x1b]22;vertical-text\x1b\\", sequence(.vertical_text));
}
