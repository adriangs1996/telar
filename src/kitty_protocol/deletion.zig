//! Kitty image and placement deletion encoding.

const std = @import("std");
const command = @import("command.zig");

/// Deletes an image and its placements.
/// For example: `try writeDeleteImage(writer, image_id)`.
pub fn writeDeleteImage(writer: *std.Io.Writer, image_id: u32) std.Io.Writer.Error!usize {
    return command.print(writer, "\x1b_Ga=d,d=I,i={d},q=2\x1b\\", .{image_id});
}

/// Deletes one placement of an image.
/// For example: `try writeDeletePlacement(writer, image_id, placement_id)`.
pub fn writeDeletePlacement(writer: *std.Io.Writer, image_id: u32, placement_id: u32) std.Io.Writer.Error!usize {
    return command.print(writer, "\x1b_Ga=d,d=i,i={d},p={d},q=2\x1b\\", .{ image_id, placement_id });
}

/// Deletes every image whose ID is inside the inclusive range.
/// For example: `try writeDeleteImageRange(writer, first, last)`.
pub fn writeDeleteImageRange(writer: *std.Io.Writer, first: u32, last: u32) std.Io.Writer.Error!usize {
    return command.print(writer, "\x1b_Ga=d,d=R,x={d},y={d},q=2\x1b\\", .{ first, last });
}

test "deletion commands encode exact identities" {
    var output: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    _ = try writeDeleteImage(&writer, 7);
    _ = try writeDeletePlacement(&writer, 8, 9);
    _ = try writeDeleteImageRange(&writer, 10, 12);

    try std.testing.expectEqualStrings(
        "\x1b_Ga=d,d=I,i=7,q=2\x1b\\" ++
            "\x1b_Ga=d,d=i,i=8,p=9,q=2\x1b\\" ++
            "\x1b_Ga=d,d=R,x=10,y=12,q=2\x1b\\",
        writer.buffered(),
    );
}
