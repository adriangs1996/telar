const bytecodec = @import("bytecodec");
const cellgrid = @import("cellgrid");
const std = @import("std");
const cell_run = @import("cell_run.zig");
const CellReader = @import("CellReader.zig");
const Encoder = bytecodec.Encoder;
const Cell = cellgrid.Cell;
const Color = cellgrid.cell_support.Color;

const unlimited = std.math.maxInt(usize);

fn textCell(byte: u8, style: cellgrid.Style) Cell {
    return .{
        .bytes = [_]u8{byte} ++ [_]u8{0} ** (Cell.max_bytes - 1),
        .len = 1,
        .width = 1,
        .style = style,
    };
}

test "a run round trips and writes a repeated style once" {
    const accent: cellgrid.Style = .{
        .fg = .rgb(.{ 1, 2, 3 }),
        .bg = .indexed(4),
        .flags = .{ .bold = true, .underline = .curly },
    };
    const cells = [_]Cell{ .{}, textCell('a', accent), textCell('b', accent) };
    var buffer: [128]u8 = undefined;
    var encoder = Encoder.init(&buffer);

    try cell_run.encode(&encoder, &cells, unlimited);

    try std.testing.expectEqual(cell_run.encodedCellsSize(&cells, null), encoder.index);

    var reader = CellReader.init(encoder.finish(), cells.len);
    for (cells) |expected| {
        try std.testing.expectEqualDeep(expected, (try reader.next()).?);
    }

    try std.testing.expect((try reader.next()) == null);
}

test "cell run size accounts for inherited style" {
    const cells = [_]Cell{ .{}, .{}, .{} };

    try std.testing.expectEqual(@as(usize, 11), cell_run.encodedCellsSize(&cells, null));
    try std.testing.expectEqual(@as(usize, 6), cell_run.encodedCellsSize(&cells, .{}));
}

test "the first cell of a run must define its style" {
    const cells = [_]Cell{.{}};
    var buffer: [32]u8 = undefined;
    var encoder = Encoder.init(&buffer);
    try cell_run.encode(&encoder, &cells, unlimited);

    buffer[0] &= ~cell_run.style_changed_bit;

    var reader = CellReader.init(encoder.finish(), cells.len);
    try std.testing.expectError(error.InvalidCell, reader.next());
}

test "bytes after the promised cells are rejected" {
    const cells = [_]Cell{.{}};
    var buffer: [32]u8 = undefined;
    var encoder = Encoder.init(&buffer);
    try cell_run.encode(&encoder, &cells, unlimited);
    try encoder.writeByte(0);

    var reader = CellReader.init(encoder.finish(), cells.len);
    try std.testing.expectError(error.TrailingBytes, reader.next());
}

test "a run stops at the caller's limit before the buffer fills" {
    const cells = [_]Cell{ .{}, .{}, .{} };
    const size = cell_run.encodedCellsSize(&cells, null);
    var buffer: [128]u8 = undefined;
    var encoder = Encoder.init(&buffer);

    try std.testing.expectError(error.LimitExceeded, cell_run.encode(&encoder, &cells, size - 1));

    encoder = Encoder.init(&buffer);
    try cell_run.encode(&encoder, &cells, size);
    try std.testing.expectEqual(size, encoder.index);
}

test "reserved cell runs encode the same bytes as checked runs" {
    var random = std.Random.DefaultPrng.init(0x5eed);
    const rng = random.random();
    var cells: [257]Cell = undefined;
    for (&cells) |*cell| {
        const colors = [_]Color{ .default, .indexed(rng.int(u8)), .rgb(.{ rng.int(u8), rng.int(u8), rng.int(u8) }) };
        const len = rng.intRangeAtMost(u8, 1, Cell.max_bytes);
        cell.* = .{
            .len = len,
            .width = rng.intRangeAtMost(u8, 1, 2),
            .style = .{
                .fg = colors[rng.uintLessThan(usize, colors.len)],
                .bg = if (rng.boolean()) colors[rng.uintLessThan(usize, colors.len)] else .default,
                .flags = .{ .bold = rng.boolean(), .underline = if (rng.boolean()) .curly else .none },
            },
        };
        for (cell.bytes[0..len]) |*byte| {
            byte.* = rng.intRangeAtMost(u8, 'a', 'z');
        }
    }

    var reserved_storage: [cells.len * cell_run.max_cell_size]u8 = undefined;
    var reserved = Encoder.init(&reserved_storage);
    try cell_run.encode(&reserved, &cells, unlimited);

    var exact_storage: [cells.len * cell_run.max_cell_size]u8 = undefined;
    var checked = Encoder.init(exact_storage[0..reserved.index]);
    try cell_run.encode(&checked, &cells, unlimited);

    try std.testing.expectEqualSlices(u8, checked.finish(), reserved.finish());
    try std.testing.expectEqual(cell_run.encodedCellsSize(&cells, null), reserved.index);
}
