//! OSC 22 pointer shapes: an enum tag's name as the CSS cursor name, with
//! underscores written as dashes.
const std = @import("std");
const sequences = @import("sequences.zig");

/// Encodes the shape named by an enum tag without allocating.
///
/// ```zig
/// try writer.writeAll(pointer.sequence(shape));
/// ```
pub fn sequence(shape: anytype) []const u8 {
    return switch (shape) {
        inline else => |value| comptime shapeSequence(value),
    };
}

fn shapeSequence(comptime shape: anytype) []const u8 {
    const tag = @tagName(shape);
    var name: [tag.len]u8 = undefined;

    for (tag, 0..) |byte, index| {
        name[index] = if (byte == '_') '-' else byte;
    }

    return "\x1b]22;" ++ name ++ "\x1b\\";
}

test "shape tags become CSS cursor names and the default resets" {
    const Shape = enum { default, pointer, ew_resize, vertical_text };

    try std.testing.expectEqualStrings(sequences.reset_pointer, sequence(Shape.default));
    try std.testing.expectEqualStrings("\x1b]22;pointer\x1b\\", sequence(Shape.pointer));
    try std.testing.expectEqualStrings("\x1b]22;ew-resize\x1b\\", sequence(Shape.ew_resize));
    try std.testing.expectEqualStrings("\x1b]22;vertical-text\x1b\\", sequence(Shape.vertical_text));
}
