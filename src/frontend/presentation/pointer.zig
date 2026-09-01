//! OSC 22 mouse-pointer shapes emitted by the host presentation path.

const std = @import("std");

pub const reset_sequence = "\x1b]22;default\x1b\\";

pub const Shape = enum {
    default,
    pointer,
    horizontal_resize,
};

/// Encodes one bounded pointer shape without allocating.
///
/// ```zig
/// try writer.writeAll(sequence(.pointer));
/// ```
pub fn sequence(shape: Shape) []const u8 {
    return switch (shape) {
        .default => reset_sequence,
        .pointer => "\x1b]22;pointer\x1b\\",
        .horizontal_resize => "\x1b]22;ew-resize\x1b\\",
    };
}

test "pointer shapes use explicit CSS names including the default" {
    try std.testing.expectEqualStrings("\x1b]22;default\x1b\\", sequence(.default));
    try std.testing.expectEqualStrings("\x1b]22;pointer\x1b\\", sequence(.pointer));
    try std.testing.expectEqualStrings("\x1b]22;ew-resize\x1b\\", sequence(.horizontal_resize));
}
