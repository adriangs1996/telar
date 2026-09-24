const console = @import("console");
const core = @import("telar-core");
const std = @import("std");
const Screen = @import("Screen.zig");

test "the diff sends only what changed" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 40, 10);
    defer screen.deinit();

    var out: [16 * 1024]u8 = undefined;

    { // First frame: everything is new.
        var w = std.Io.Writer.fixed(&out);
        screen.buffer().clear(.{});
        _ = screen.buffer().writeText(screen.buffer().area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "hello", .style = .{} });
        const stats = try screen.flush(&w);
        try std.testing.expectEqual(@as(usize, 40 * 10), stats.cells);
        try std.testing.expectEqual(@as(usize, 40 * 10), stats.scanned);
    }

    { // Redrawing the same thing costs nothing at all.
        var w = std.Io.Writer.fixed(&out);
        screen.buffer().clear(.{});
        _ = screen.buffer().writeText(screen.buffer().area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "hello", .style = .{} });
        const stats = try screen.flush(&w);
        try std.testing.expectEqual(@as(usize, 0), stats.cells);
        try std.testing.expectEqual(@as(usize, 40 * 10), stats.scanned);
    }

    { // One changed word costs one word.
        var w = std.Io.Writer.fixed(&out);
        screen.buffer().clear(.{});
        _ = screen.buffer().writeText(screen.buffer().area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "world", .style = .{} });
        const stats = try screen.flush(&w);
        try std.testing.expectEqual(@as(usize, 4), stats.cells); // h,e,l,l -> w,o,r,l
    }
}

test "a resize forces a full repaint" {
    // Otherwise the diff compares against a screen the terminal no longer has,
    // and the result is the half drawn window everyone recognises.
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 10, 3);
    defer screen.deinit();

    var out: [8 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    screen.buffer().clear(.{});
    _ = try screen.flush(&w);

    try screen.resize(12, 4);
    var w2 = std.Io.Writer.fixed(&out);
    screen.buffer().clear(.{});
    const stats = try screen.flush(&w2);
    try std.testing.expectEqual(@as(usize, 12 * 4), stats.cells);
    try std.testing.expectEqual(@as(usize, 12 * 4), stats.scanned);
}

test "a protocol patch scans only its damaged cells" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 10, 3);
    defer screen.deinit();

    var out: [8 * 1024]u8 = undefined;
    var initial = std.Io.Writer.fixed(&out);
    _ = try screen.flush(&initial);

    const patch = try screen.patchCells(12, 2);
    patch[0].bytes[0] = 'x';
    patch[1].bytes[0] = 'y';

    var writer = std.Io.Writer.fixed(&out);
    const stats = try screen.flush(&writer);
    try std.testing.expectEqual(@as(usize, 2), stats.scanned);
    try std.testing.expectEqual(@as(usize, 2), stats.cells);
}

test "damage accumulates as one conservative range per row" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 10, 2);
    defer screen.deinit();

    var out: [8 * 1024]u8 = undefined;
    var initial = std.Io.Writer.fixed(&out);
    _ = try screen.flush(&initial);

    const left = try screen.patchCells(1, 1);
    left[0].bytes[0] = 'x';
    const right = try screen.patchCells(8, 1);
    right[0].bytes[0] = 'y';

    var writer = std.Io.Writer.fixed(&out);
    const stats = try screen.flush(&writer);
    try std.testing.expectEqual(@as(usize, 8), stats.scanned);
    try std.testing.expectEqual(@as(usize, 2), stats.cells);
}

test "a patch crossing rows keeps exact damage on both" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 10, 2);
    defer screen.deinit();

    var out: [8 * 1024]u8 = undefined;
    var initial = std.Io.Writer.fixed(&out);
    _ = try screen.flush(&initial);

    const patch = try screen.patchCells(8, 4);
    for (patch, 0..) |*cell, index| cell.bytes[0] = @intCast('a' + index);

    var writer = std.Io.Writer.fixed(&out);
    const stats = try screen.flush(&writer);
    try std.testing.expectEqual(@as(usize, 4), stats.scanned);
    try std.testing.expectEqual(@as(usize, 4), stats.cells);
}

test "a cursor-only frame scans no cells" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 10, 2);
    defer screen.deinit();

    var out: [8 * 1024]u8 = undefined;
    var initial = std.Io.Writer.fixed(&out);
    _ = try screen.flush(&initial);

    screen.cursor = .{ .x = 3, .y = 1 };
    var writer = std.Io.Writer.fixed(&out);
    const stats = try screen.flush(&writer);
    try std.testing.expectEqual(@as(usize, 0), stats.scanned);
    try std.testing.expectEqual(@as(usize, 0), stats.cells);
}

test "the real cursor is placed only when a field asks for it" {
    // A hardware cursor parked wherever the last write landed is a
    // distraction, so the default is hidden. A text field is the exception,
    // and it is the only thing a screen reader or an input method can follow.
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 10, 3);
    defer screen.deinit();

    var out: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);

    _ = try screen.flush(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[?25l") != null);

    writer = .fixed(&out);
    screen.cursor = .{ .x = 4, .y = 1 };
    _ = try screen.flush(&writer);
    // One based, row first, and shown.
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[2;5H") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[?25h") != null);
}

test "mouse pointer changes fold until a shape or recovery changes" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 10, 3);
    defer screen.deinit();

    var out: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);

    _ = try screen.flush(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), console.pointer.sequence(.default)) != null);

    writer = .fixed(&out);
    screen.mouse_pointer = .pointer;
    _ = try screen.flush(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), console.pointer.sequence(.pointer)) != null);

    writer = .fixed(&out);
    _ = try screen.flush(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b]22;") == null);

    writer = .fixed(&out);
    screen.mouse_pointer = .ew_resize;
    _ = try screen.flush(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), console.pointer.sequence(.ew_resize)) != null);

    writer = .fixed(&out);
    screen.invalidate();
    _ = try screen.flush(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), console.pointer.sequence(.ew_resize)) != null);
}

test "a failed flush forgets nothing the terminal did not receive" {
    // Regression: the diff committed cells into `front` while emitting them,
    // so a writer error mid-flush left the screen claiming cells the terminal
    // never got, and the retry emitted nothing.
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 10, 2);
    defer screen.deinit();
    var out: [8 * 1024]u8 = undefined;
    var initial = std.Io.Writer.fixed(&out);
    screen.buffer().clear(.{});
    _ = try screen.flush(&initial);

    screen.buffer().clear(.{});
    _ = screen.buffer().writeText(screen.buffer().area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "hola", .style = .{} });
    var tiny: [24]u8 = undefined;
    var failing = std.Io.Writer.fixed(&tiny);
    try std.testing.expectError(error.WriteFailed, screen.flush(&failing));

    var retry = std.Io.Writer.fixed(&out);
    const stats = try screen.flush(&retry);
    try std.testing.expect(stats.cells >= 4);
}

test "every wire pointer shape has a bounded CSS sequence" {
    inline for (std.meta.tags(core.PointerShape)) |shape| {
        const encoded = console.pointer.sequence(shape);
        try std.testing.expect(std.mem.startsWith(u8, encoded, "\x1b]22;"));
        try std.testing.expect(std.mem.endsWith(u8, encoded, "\x1b\\"));
        try std.testing.expect(encoded.len <= 20);

        for (encoded[5 .. encoded.len - 2]) |byte| {
            try std.testing.expect(std.ascii.isLower(byte) or byte == '-');
        }
    }

    try std.testing.expectEqualStrings(console.sequences.reset_pointer, console.pointer.sequence(core.PointerShape.default));
}
