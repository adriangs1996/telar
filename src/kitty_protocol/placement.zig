//! Kitty image placement encoding.

const std = @import("std");
const PlacementCommand = @import("PlacementCommand.zig");
const command = @import("command.zig");

/// Places an image without applying application-specific z-index policy.
/// For example: `try writePlacement(writer, placement)`.
pub fn writePlacement(writer: *std.Io.Writer, placement: PlacementCommand) std.Io.Writer.Error!usize {
    const value = placement.value;
    var written = try command.print(writer, "\x1b[{d};{d}H", .{ value.row + 1, value.column + 1 });
    written += try command.print(
        writer,
        "\x1b_Ga=p,i={d},p={d},x={d},y={d},w={d},h={d},c={d},r={d},X={d},Y={d},z={d},C=1,q=2\x1b\\",
        .{ placement.image_id, placement.placement_id, value.source_x, value.source_y, value.source_width, value.source_height, value.columns, value.rows, value.offset_x, value.offset_y, placement.z },
    );

    return written;
}

test "placement preserves the caller's z-index" {
    var output: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    _ = try writePlacement(&writer, .{
        .image_id = 7,
        .placement_id = 9,
        .value = .{
            .column = 2,
            .row = 3,
            .offset_x = 0,
            .offset_y = 0,
            .source_x = 0,
            .source_y = 0,
            .source_width = 16,
            .source_height = 8,
            .columns = 4,
            .rows = 2,
        },
        .z = 2001,
    });

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[4;3H") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), ",z=2001,C=1,q=2") != null);
}
