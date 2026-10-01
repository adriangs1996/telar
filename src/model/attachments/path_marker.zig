//! Pi's pasted-image marker: the temporary file path its editor inserts.
//!
//! Pi has no atomic image placeholder. `Ctrl+V` writes the clipboard image to
//! `<tmpdir>/pi-clipboard-<uuid>.<ext>` and inserts that path as plain text at
//! the cursor. The path is one editor step per grapheme, its editor wraps long
//! words at grapheme granularity into rows of `width - 1` cells, and the
//! hardware cursor is hidden by default in favour of one inverse-video cell.
//! This module reads those conventions back from a committed pane frame.

const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const Marker = @import("Marker.zig");
const Scan = @import("Scan.zig");
const std = @import("std");
const Screen = @import("Screen.zig");
const Position = @import("Position.zig");
const Span = @import("Span.zig");
const Head = @import("Head.zig");

pub const prefix = "pi-clipboard-";
pub const uuid_len: usize = 36;
/// Bound for the whole path in editor steps. A macOS `$TMPDIR` path is 102;
/// a custom `TMPDIR` can be several times longer. The bound only stops the
/// count of one marker's cells, so raising it costs scan steps, never memory.
pub const max_cells: u16 = 512;
pub const cells_limit = core.Limit.declare("attachments.path_marker.max_cells", "editor steps", max_cells);
const extensions = [_][]const u8{
    "png",
    "jpg",
    "webp",
    "gif",
};

pub const Uuid = [uuid_len]u8;

/// Finds the marker carrying `uuid` anywhere on the screen.
///
/// ```zig
/// const marker = path_marker.find(buffer, uuid) orelse return;
/// ```
pub fn find(buffer: *const cellgrid.Buffer, uuid: Uuid) ?Marker {
    var scan = Scan.start(buffer) orelse return null;
    while (scan.position()) |at| : (scan.step()) {
        const head = parseHead(buffer, at) orelse continue;
        if (std.mem.eql(
            u8,
            &head.uuid,
            &uuid,
        )) {
            return extend(buffer, head);
        }
    }

    return null;
}

/// Collects every marker in screen order, keeping the newest `out.len` when
/// there are more. Pi inserts each path at the cursor, so screen order is
/// paste order for the common sequential case.
///
/// ```zig
/// var found: [4]Marker = undefined;
/// const count = path_marker.collect(buffer, &found);
/// ```
pub fn collect(buffer: *const cellgrid.Buffer, out: []Marker) usize {
    var count: usize = 0;
    var scan = Scan.start(buffer) orelse return 0;
    while (scan.position()) |at| : (scan.step()) {
        const head = parseHead(buffer, at) orelse continue;
        var duplicate = false;
        for (out[0..count]) |known| {
            duplicate = duplicate or std.mem.eql(
                u8,
                &known.uuid,
                &head.uuid,
            );
        }
        if (duplicate) {
            continue;
        }

        if (count == out.len) {
            std.mem.copyForwards(
                Marker,
                out[0 .. count - 1],
                out[1..count],
            );
            count -= 1;
        }
        out[count] = extend(buffer, head);
        count += 1;
    }

    return count;
}

/// Reports whether the editor cursor sits on `at`. The hardware cursor wins
/// when the child shows it; otherwise Pi's cursor is the only isolated
/// inverse-video cell on its row.
///
/// ```zig
/// if (path_marker.cursorAt(screen, marker.end)) retire(id);
/// ```
pub fn cursorAt(screen: Screen, at: Position) bool {
    if (screen.cursor.visible) {
        return screen.cursor.x == at.x and screen.cursor.y == at.y;
    }

    return isolatedInverse(screen.buffer, at);
}

/// Resolves the editor cursor column on one row, or null when the row holds
/// no cursor.
///
/// ```zig
/// const column = path_marker.cursorOnRow(screen, marker.end.y) orelse return;
/// ```
pub fn cursorOnRow(screen: Screen, y: u16) ?u16 {
    if (screen.cursor.visible) {
        return if (screen.cursor.y == y) screen.cursor.x else null;
    }

    var x: u16 = 0;
    while (x < screen.buffer.w) : (x += 1) {
        if (isolatedInverse(
            screen.buffer,
            .{
                .x = x,
                .y = y,
            },
        )) {
            return x;
        }
    }

    return null;
}

/// Counts editor steps between two columns of one row. Pi's editor moves one
/// grapheme per arrow key, so wide glyphs count once and their tails never.
///
/// ```zig
/// const steps = path_marker.stepsOnRow(buffer, marker.end.y, .{ .from = marker.end.x, .to = cursor_x }) orelse return;
/// ```
pub fn stepsOnRow(buffer: *const cellgrid.Buffer, y: u16, span: Span) ?u16 {
    if (span.from > span.to or span.to > buffer.w or y >= buffer.h) {
        return null;
    }

    var steps: u16 = 0;
    var x = span.from;
    while (x < span.to) : (x += 1) {
        steps += @intFromBool(cellAt(
            buffer,
            x,
            y,
        ).width != 0);
    }

    return steps;
}

fn parseHead(buffer: *const cellgrid.Buffer, start: Position) ?Head {
    var scan = Scan.at(buffer, start) orelse return null;
    for (prefix) |byte| {
        if (!scan.expect(byte)) {
            return null;
        }
    }

    var uuid: Uuid = undefined;
    for (&uuid, 0..) |*slot, index| {
        const here = scan.cell() orelse return null;
        if (!isSingle(here)) {
            return null;
        }

        const byte = here.text()[0];
        const dash = index == 8 or index == 13 or index == 18 or index == 23;
        if (dash and byte != '-') {
            return null;
        }
        if (!dash and !std.ascii.isHex(byte)) {
            return null;
        }
        slot.* = byte;
        scan.step();
    }
    if (!scan.expect('.')) {
        return null;
    }

    const end = matchExtension(scan) orelse return null;
    if (end.x < buffer.w - 1) {
        const following = cellAt(
            buffer,
            end.x,
            end.y,
        );
        if (isSingle(following) and std.ascii.isAlphanumeric(following.text()[0])) {
            return null;
        }
    }

    return .{
        .uuid = uuid,
        .start = start,
        .end = end,
    };
}

/// Matches one of Pi's image extensions, crossing a forced wrap inside the
/// extension but never reading past it into a soft-wrapped next word.
fn matchExtension(scan: Scan) ?Position {
    for (extensions) |extension| {
        var attempt = scan;
        var matched = true;
        for (extension) |byte| {
            matched = matched and attempt.expect(byte);
        }
        if (matched) {
            return .{
                .x = attempt.x,
                .y = attempt.y,
            };
        }
    }

    return null;
}

fn extend(buffer: *const cellgrid.Buffer, head: Head) Marker {
    const start = pathStart(buffer, head.start);

    return .{
        .uuid = head.uuid,
        .start = start,
        .end = head.end,
        .cells = countCells(
            buffer,
            start,
            head.end,
        ),
    };
}

/// Walks back over the word holding the file name, following force-wrapped
/// rows, and returns its first `/`. A word broken by Pi's grapheme wrapping
/// fills the row up to the reserved cursor column.
fn pathStart(buffer: *const cellgrid.Buffer, marker: Position) Position {
    var x = marker.x;
    var y = marker.y;
    var slash: ?Position = null;
    while (true) {
        if (x == 0) {
            if (y == 0 or !rowForceWrapped(buffer, y - 1)) {
                break;
            }

            y -= 1;
            x = buffer.w - 1;
            continue;
        }

        const previous = cellAt(
            buffer,
            x - 1,
            y,
        );
        if (previous.width == 0) {
            x -= 1;
            continue;
        }
        if (isBlank(previous)) {
            break;
        }

        x -= 1;
        if (isSingle(previous) and previous.text()[0] == '/') {
            slash = .{
                .x = x,
                .y = y,
            };
        }
    }

    return slash orelse marker;
}

fn rowForceWrapped(buffer: *const cellgrid.Buffer, y: u16) bool {
    const last_content = cellAt(
        buffer,
        buffer.w - 2,
        y,
    );
    const reserved = cellAt(
        buffer,
        buffer.w - 1,
        y,
    );

    return !isBlank(last_content) and isBlank(reserved);
}

fn countCells(buffer: *const cellgrid.Buffer, start: Position, end: Position) ?u16 {
    var scan = Scan.at(buffer, start) orelse return null;
    var cells: u16 = 0;
    while (true) {
        if (scan.x == end.x and scan.y == end.y) {
            return cells;
        }

        const here = scan.position() orelse return null;
        cells += @intFromBool(cellAt(
            buffer,
            here.x,
            here.y,
        ).width != 0);
        if (cells > max_cells) {
            return null;
        }
        scan.step();
    }
}

fn isolatedInverse(buffer: *const cellgrid.Buffer, at: Position) bool {
    if (at.x >= buffer.w or at.y >= buffer.h) {
        return false;
    }
    if (!cellAt(
        buffer,
        at.x,
        at.y,
    ).style.flags.inverse) {
        return false;
    }

    const left_inverse = at.x != 0 and cellAt(
        buffer,
        at.x - 1,
        at.y,
    ).style.flags.inverse;
    const right_inverse = at.x + 1 < buffer.w and cellAt(
        buffer,
        at.x + 1,
        at.y,
    ).style.flags.inverse;

    return !left_inverse and !right_inverse;
}

pub fn cellAt(buffer: *const cellgrid.Buffer, x: u16, y: u16) *const cellgrid.Cell {
    return &buffer.cells[@as(usize, y) * buffer.w + x];
}

pub fn isSingle(cell: *const cellgrid.Cell) bool {
    return cell.width == 1 and cell.len == 1;
}

fn isBlank(cell: *const cellgrid.Cell) bool {
    return cell.len == 0 or (cell.len == 1 and cell.bytes[0] == ' ');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_uuid = "3f2a9c1e-7b4d-4e8f-9a0b-1c2d3e4f5a6b";
const test_path = "/var/folders/8x/abc/T/pi-clipboard-" ++ test_uuid ++ ".png";

/// Lays `text` out like Pi's editor: rows of `width - 1` cells, broken at
/// any grapheme once the row is full.
fn writeWrapped(buffer: *cellgrid.Buffer, origin: Position, text: []const u8) Position {
    var x = origin.x;
    var y = origin.y;
    for (text) |byte| {
        if (x == buffer.w - 1) {
            x = 0;
            y += 1;
        }
        buffer.setCell(
            .{
                .x = x,
                .y = y,
            },
            .{
                .text = &.{
                    byte,
                },
                .width = 1,
                .style = .{},
            },
        );
        x += 1;
    }

    return .{
        .x = x,
        .y = y,
    };
}

test "a pasted path on one row is one marker with its full extent" {
    var buffer = try cellgrid.Buffer.init(
        std.testing.allocator,
        120,
        2,
    );
    defer buffer.deinit();
    _ = buffer.writeText(
        buffer.area(),
        .{
            .point = .{
                .x = 0,
                .y = 0,
            },
            .text = "see " ++ test_path ++ " now",
            .style = .{},
        },
    );

    const marker = find(&buffer, test_uuid.*).?;

    try std.testing.expectEqual(
        Position{
            .x = 4,
            .y = 0,
        },
        marker.start,
    );
    try std.testing.expectEqual(
        Position{
            .x = 4 + test_path.len,
            .y = 0,
        },
        marker.end,
    );
    try std.testing.expectEqual(@as(?u16, test_path.len), marker.cells);
}

test "a path broken over force-wrapped rows keeps one identity and extent" {
    var buffer = try cellgrid.Buffer.init(
        std.testing.allocator,
        40,
        4,
    );
    defer buffer.deinit();
    const end = writeWrapped(
        &buffer,
        .{
            .x = 0,
            .y = 0,
        },
        "look at " ++ test_path,
    );

    const marker = find(&buffer, test_uuid.*).?;

    try std.testing.expectEqual(
        Position{
            .x = 8,
            .y = 0,
        },
        marker.start,
    );
    try std.testing.expectEqual(end, marker.end);
    try std.testing.expectEqual(@as(?u16, test_path.len), marker.cells);
}

/// A path of exactly `cells` cells ending in the test marker's file name.
fn pathOfCells(comptime cells: usize) *const [cells]u8 {
    const file = "/pi-clipboard-" ++ test_uuid ++ ".png";
    return comptime "/" ++ ("d" ** (cells - file.len - 1)) ++ file;
}

test "a path counts its cells up to max_cells and stays recognisable past them" {
    var buffer = try cellgrid.Buffer.init(
        std.testing.allocator,
        120,
        6,
    );
    defer buffer.deinit();

    // A custom TMPDIR four times as long as macOS's keeps its extent.
    _ = writeWrapped(
        &buffer,
        .{
            .x = 0,
            .y = 0,
        },
        pathOfCells(max_cells),
    );
    try std.testing.expectEqual(@as(?u16, max_cells), find(&buffer, test_uuid.*).?.cells);

    buffer.clear(.{});
    _ = writeWrapped(
        &buffer,
        .{
            .x = 0,
            .y = 0,
        },
        pathOfCells(max_cells + 1),
    );
    const past = find(&buffer, test_uuid.*).?;
    try std.testing.expect(past.cells == null);
    try std.testing.expectEqual(
        Position{
            .x = 0,
            .y = 0,
        },
        past.start,
    );
}

test "a word soft-wrapped before the path is not part of its extent" {
    var buffer = try cellgrid.Buffer.init(
        std.testing.allocator,
        40,
        4,
    );
    defer buffer.deinit();
    // "image" fills the last content column of row 0 exactly, then the path
    // starts on row 1 like Pi lays out a wrap opportunity.
    const lead = "x" ** 33 ++ " image";
    _ = buffer.writeText(
        buffer.area(),
        .{
            .point = .{
                .x = 0,
                .y = 0,
            },
            .text = lead,
            .style = .{},
        },
    );
    const end = writeWrapped(
        &buffer,
        .{
            .x = 0,
            .y = 1,
        },
        test_path,
    );

    const marker = find(&buffer, test_uuid.*).?;

    try std.testing.expectEqual(
        Position{
            .x = 0,
            .y = 1,
        },
        marker.start,
    );
    try std.testing.expectEqual(end, marker.end);
    try std.testing.expectEqual(@as(?u16, test_path.len), marker.cells);
}

test "a file name glued to following text is no longer a marker" {
    var buffer = try cellgrid.Buffer.init(
        std.testing.allocator,
        120,
        1,
    );
    defer buffer.deinit();
    _ = buffer.writeText(
        buffer.area(),
        .{
            .point = .{
                .x = 0,
                .y = 0,
            },
            .text = test_path ++ "x",
            .style = .{},
        },
    );

    try std.testing.expect(find(&buffer, test_uuid.*) == null);

    buffer.clear(
        .{},
    );
    _ = buffer.writeText(
        buffer.area(),
        .{
            .point = .{
                .x = 0,
                .y = 0,
            },
            .text = test_path ++ ",",
            .style = .{},
        },
    );
    try std.testing.expect(find(&buffer, test_uuid.*) != null);
}

test "markers collect in screen order and keep the newest when full" {
    var buffer = try cellgrid.Buffer.init(
        std.testing.allocator,
        80,
        3,
    );
    defer buffer.deinit();
    const uuids = [_]*const [uuid_len]u8{
        "11111111-1111-4111-8111-111111111111",
        "22222222-2222-4222-8222-222222222222",
        "33333333-3333-4333-8333-333333333333",
    };
    for (uuids, 0..) |uuid, row| {
        _ = buffer.writeText(
            buffer.area(),
            .{
                .point = .{
                    .x = 0,
                    .y = @intCast(row),
                },
                .text = "/tmp/pi-clipboard-" ++ uuid.* ++ ".jpg",
                .style = .{},
            },
        );
    }

    var found: [2]Marker = undefined;
    const count = collect(&buffer, &found);

    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings(uuids[1], &found[0].uuid);
    try std.testing.expectEqualStrings(uuids[2], &found[1].uuid);
}

test "the cursor is the hardware cursor or Pi's isolated inverse cell" {
    var buffer = try cellgrid.Buffer.init(
        std.testing.allocator,
        20,
        2,
    );
    defer buffer.deinit();
    _ = buffer.writeText(
        buffer.area(),
        .{
            .point = .{
                .x = 0,
                .y = 0,
            },
            .text = "abc",
            .style = .{},
        },
    );
    buffer.setCell(
        .{
            .x = 3,
            .y = 0,
        },
        .{
            .text = " ",
            .width = 1,
            .style = .{
                .flags = .{
                    .inverse = true,
                },
            },
        },
    );
    _ = buffer.writeText(
        buffer.area(),
        .{
            .point = .{
                .x = 0,
                .y = 1,
            },
            .text = "sel",
            .style = .{
                .flags = .{
                    .inverse = true,
                },
            },
        },
    );

    const hidden: Screen = .{
        .buffer = &buffer,
        .cursor = .{
            .visible = false,
            .x = 0,
            .y = 0,
        },
    };
    try std.testing.expect(cursorAt(
        hidden,
        .{
            .x = 3,
            .y = 0,
        },
    ));
    try std.testing.expect(!cursorAt(
        hidden,
        .{
            .x = 1,
            .y = 1,
        },
    ));
    try std.testing.expectEqual(@as(?u16, 3), cursorOnRow(hidden, 0));
    try std.testing.expect(cursorOnRow(hidden, 1) == null);

    const shown: Screen = .{
        .buffer = &buffer,
        .cursor = .{
            .visible = true,
            .x = 1,
            .y = 0,
        },
    };
    try std.testing.expect(cursorAt(
        shown,
        .{
            .x = 1,
            .y = 0,
        },
    ));
    try std.testing.expect(!cursorAt(
        shown,
        .{
            .x = 3,
            .y = 0,
        },
    ));
    try std.testing.expectEqual(@as(?u16, 1), cursorOnRow(shown, 0));
}

test "row steps count graphemes rather than cells" {
    var buffer = try cellgrid.Buffer.init(
        std.testing.allocator,
        20,
        1,
    );
    defer buffer.deinit();
    _ = buffer.writeText(
        buffer.area(),
        .{
            .point = .{
                .x = 0,
                .y = 0,
            },
            .text = "a日b",
            .style = .{},
        },
    );

    try std.testing.expectEqual(@as(?u16, 3), stepsOnRow(
        &buffer,
        0,
        .{
            .from = 0,
            .to = 4,
        },
    ));
    try std.testing.expect(stepsOnRow(
        &buffer,
        0,
        .{
            .from = 4,
            .to = 0,
        },
    ) == null);
}
