//! Pi's pasted-image marker: the temporary file path its editor inserts.
//!
//! Pi has no atomic image placeholder. `Ctrl+V` writes the clipboard image to
//! `<tmpdir>/pi-clipboard-<uuid>.<ext>` and inserts that path as plain text at
//! the cursor. The path is one editor step per grapheme, its editor wraps long
//! words at grapheme granularity into rows of `width - 1` cells, and the
//! hardware cursor is hidden by default in favour of one inverse-video cell.
//! This module reads those conventions back from a committed pane frame.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;
const ui = core.ui;

pub const prefix = "pi-clipboard-";
pub const uuid_len: usize = 36;
/// Bound for the whole path in editor steps. A macOS `$TMPDIR` path is 102.
pub const max_cells: u8 = 128;
const extensions = [_][]const u8{ "png", "jpg", "webp", "gif" };

pub const Uuid = [uuid_len]u8;

pub const Position = struct {
    x: u16,
    y: u16,

    pub fn eql(a: Position, b: Position) bool {
        return a.x == b.x and a.y == b.y;
    }
};

pub const Marker = struct {
    uuid: Uuid,
    /// First cell of the path, which is the first `/` of the word holding
    /// the file name so a word soft-wrapped before it is never included.
    start: Position,
    /// One past the last extension cell on its row.
    end: Position,
    /// Editor steps from `start` to `end`, or null when the path exceeds
    /// `max_cells`. A marker is still recognisable without its extent.
    cells: ?u8,
};

pub const Screen = struct {
    buffer: *const ui.Buffer,
    cursor: schema.frame.Cursor,
};

/// Finds the marker carrying `uuid` anywhere on the screen.
///
/// ```zig
/// const marker = path_marker.find(buffer, uuid) orelse return;
/// ```
pub fn find(buffer: *const ui.Buffer, uuid: Uuid) ?Marker {
    var scan = Scan.start(buffer) orelse return null;
    while (scan.position()) |at| : (scan.step()) {
        const head = parseHead(buffer, at) orelse continue;
        if (std.mem.eql(u8, &head.uuid, &uuid)) {
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
pub fn collect(buffer: *const ui.Buffer, out: []Marker) usize {
    var count: usize = 0;
    var scan = Scan.start(buffer) orelse return 0;
    while (scan.position()) |at| : (scan.step()) {
        const head = parseHead(buffer, at) orelse continue;
        var duplicate = false;
        for (out[0..count]) |known| {
            duplicate = duplicate or std.mem.eql(u8, &known.uuid, &head.uuid);
        }
        if (duplicate) {
            continue;
        }

        if (count == out.len) {
            std.mem.copyForwards(Marker, out[0 .. count - 1], out[1..count]);
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
        if (isolatedInverse(screen.buffer, .{ .x = x, .y = y })) {
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
pub fn stepsOnRow(buffer: *const ui.Buffer, y: u16, span: Span) ?u8 {
    if (span.from > span.to or span.to > buffer.w or y >= buffer.h) {
        return null;
    }

    var steps: u16 = 0;
    var x = span.from;
    while (x < span.to) : (x += 1) {
        steps += @intFromBool(cellAt(buffer, x, y).width != 0);
    }
    if (steps > std.math.maxInt(u8)) {
        return null;
    }

    return @intCast(steps);
}

pub const Span = struct {
    from: u16,
    to: u16,
};

const Head = struct {
    uuid: Uuid,
    start: Position,
    end: Position,
};

/// Walks cells in Pi's logical order: left to right, then down to the next
/// row whenever a row's reserved cursor column is reached. Rows are always
/// `width - 1` content cells wide, so any content beyond that column belongs
/// to the next row.
const Scan = struct {
    buffer: *const ui.Buffer,
    x: u16,
    y: u16,

    fn start(buffer: *const ui.Buffer) ?Scan {
        if (buffer.w < 2 or buffer.h == 0) {
            return null;
        }

        return .{ .buffer = buffer, .x = 0, .y = 0 };
    }

    fn at(buffer: *const ui.Buffer, origin: Position) ?Scan {
        if (buffer.w < 2 or origin.y >= buffer.h or origin.x >= buffer.w) {
            return null;
        }

        return .{ .buffer = buffer, .x = origin.x, .y = origin.y };
    }

    /// The current cell, or null once the screen is exhausted.
    fn position(scan: *Scan) ?Position {
        if (scan.x >= scan.buffer.w - 1) {
            scan.x = 0;
            scan.y += 1;
        }
        if (scan.y >= scan.buffer.h) {
            return null;
        }

        return .{ .x = scan.x, .y = scan.y };
    }

    fn cell(scan: *Scan) ?*const ui.Cell {
        const here = scan.position() orelse return null;

        return cellAt(scan.buffer, here.x, here.y);
    }

    fn step(scan: *Scan) void {
        scan.x += 1;
    }

    fn expect(scan: *Scan, byte: u8) bool {
        const here = scan.cell() orelse return false;
        if (!isSingle(here) or here.text()[0] != byte) {
            return false;
        }
        scan.step();

        return true;
    }
};

fn parseHead(buffer: *const ui.Buffer, start: Position) ?Head {
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
        const following = cellAt(buffer, end.x, end.y);
        if (isSingle(following) and std.ascii.isAlphanumeric(following.text()[0])) {
            return null;
        }
    }

    return .{ .uuid = uuid, .start = start, .end = end };
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
            return .{ .x = attempt.x, .y = attempt.y };
        }
    }

    return null;
}

fn extend(buffer: *const ui.Buffer, head: Head) Marker {
    const start = pathStart(buffer, head.start);

    return .{
        .uuid = head.uuid,
        .start = start,
        .end = head.end,
        .cells = countCells(buffer, start, head.end),
    };
}

/// Walks back over the word holding the file name, following force-wrapped
/// rows, and returns its first `/`. A word broken by Pi's grapheme wrapping
/// fills the row up to the reserved cursor column.
fn pathStart(buffer: *const ui.Buffer, marker: Position) Position {
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

        const previous = cellAt(buffer, x - 1, y);
        if (previous.width == 0) {
            x -= 1;
            continue;
        }
        if (isBlank(previous)) {
            break;
        }

        x -= 1;
        if (isSingle(previous) and previous.text()[0] == '/') {
            slash = .{ .x = x, .y = y };
        }
    }

    return slash orelse marker;
}

fn rowForceWrapped(buffer: *const ui.Buffer, y: u16) bool {
    const last_content = cellAt(buffer, buffer.w - 2, y);
    const reserved = cellAt(buffer, buffer.w - 1, y);

    return !isBlank(last_content) and isBlank(reserved);
}

fn countCells(buffer: *const ui.Buffer, start: Position, end: Position) ?u8 {
    var scan = Scan.at(buffer, start) orelse return null;
    var cells: u16 = 0;
    while (true) {
        if (scan.x == end.x and scan.y == end.y) {
            return @intCast(cells);
        }

        const here = scan.position() orelse return null;
        cells += @intFromBool(cellAt(buffer, here.x, here.y).width != 0);
        if (cells > max_cells) {
            return null;
        }
        scan.step();
    }
}

fn isolatedInverse(buffer: *const ui.Buffer, at: Position) bool {
    if (at.x >= buffer.w or at.y >= buffer.h) {
        return false;
    }
    if (!cellAt(buffer, at.x, at.y).style.flags.inverse) {
        return false;
    }

    const left_inverse = at.x != 0 and cellAt(buffer, at.x - 1, at.y).style.flags.inverse;
    const right_inverse = at.x + 1 < buffer.w and cellAt(buffer, at.x + 1, at.y).style.flags.inverse;

    return !left_inverse and !right_inverse;
}

fn knownExtension(extension: []const u8) bool {
    for (extensions) |known| {
        if (std.mem.eql(u8, known, extension)) {
            return true;
        }
    }

    return false;
}

fn cellAt(buffer: *const ui.Buffer, x: u16, y: u16) *const ui.Cell {
    return &buffer.cells[@as(usize, y) * buffer.w + x];
}

fn isSingle(cell: *const ui.Cell) bool {
    return cell.width == 1 and cell.len == 1;
}

fn isBlank(cell: *const ui.Cell) bool {
    return cell.len == 0 or (cell.len == 1 and cell.bytes[0] == ' ');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const test_uuid = "3f2a9c1e-7b4d-4e8f-9a0b-1c2d3e4f5a6b";
const test_path = "/var/folders/8x/abc/T/pi-clipboard-" ++ test_uuid ++ ".png";

/// Lays `text` out like Pi's editor: rows of `width - 1` cells, broken at
/// any grapheme once the row is full.
fn writeWrapped(buffer: *ui.Buffer, origin: Position, text: []const u8) Position {
    var x = origin.x;
    var y = origin.y;
    for (text) |byte| {
        if (x == buffer.w - 1) {
            x = 0;
            y += 1;
        }
        buffer.setCell(.{ .x = x, .y = y }, .{ .text = &.{byte}, .width = 1, .style = .{} });
        x += 1;
    }

    return .{ .x = x, .y = y };
}

test "a pasted path on one row is one marker with its full extent" {
    var buffer = try ui.Buffer.init(testing.allocator, 120, 2);
    defer buffer.deinit();
    _ = buffer.writeText(buffer.area(), 0, 0, "see " ++ test_path ++ " now", .{});

    const marker = find(&buffer, test_uuid.*).?;

    try testing.expectEqual(Position{ .x = 4, .y = 0 }, marker.start);
    try testing.expectEqual(Position{ .x = 4 + test_path.len, .y = 0 }, marker.end);
    try testing.expectEqual(@as(?u8, test_path.len), marker.cells);
}

test "a path broken over force-wrapped rows keeps one identity and extent" {
    var buffer = try ui.Buffer.init(testing.allocator, 40, 4);
    defer buffer.deinit();
    const end = writeWrapped(&buffer, .{ .x = 0, .y = 0 }, "look at " ++ test_path);

    const marker = find(&buffer, test_uuid.*).?;

    try testing.expectEqual(Position{ .x = 8, .y = 0 }, marker.start);
    try testing.expectEqual(end, marker.end);
    try testing.expectEqual(@as(?u8, test_path.len), marker.cells);
}

test "a word soft-wrapped before the path is not part of its extent" {
    var buffer = try ui.Buffer.init(testing.allocator, 40, 4);
    defer buffer.deinit();
    // "image" fills the last content column of row 0 exactly, then the path
    // starts on row 1 like Pi lays out a wrap opportunity.
    const lead = "x" ** 33 ++ " image";
    _ = buffer.writeText(buffer.area(), 0, 0, lead, .{});
    const end = writeWrapped(&buffer, .{ .x = 0, .y = 1 }, test_path);

    const marker = find(&buffer, test_uuid.*).?;

    try testing.expectEqual(Position{ .x = 0, .y = 1 }, marker.start);
    try testing.expectEqual(end, marker.end);
    try testing.expectEqual(@as(?u8, test_path.len), marker.cells);
}

test "a file name glued to following text is no longer a marker" {
    var buffer = try ui.Buffer.init(testing.allocator, 120, 1);
    defer buffer.deinit();
    _ = buffer.writeText(buffer.area(), 0, 0, test_path ++ "x", .{});

    try testing.expect(find(&buffer, test_uuid.*) == null);

    buffer.clear(.{});
    _ = buffer.writeText(buffer.area(), 0, 0, test_path ++ ",", .{});
    try testing.expect(find(&buffer, test_uuid.*) != null);
}

test "markers collect in screen order and keep the newest when full" {
    var buffer = try ui.Buffer.init(testing.allocator, 80, 3);
    defer buffer.deinit();
    const uuids = [_]*const [uuid_len]u8{
        "11111111-1111-4111-8111-111111111111",
        "22222222-2222-4222-8222-222222222222",
        "33333333-3333-4333-8333-333333333333",
    };
    for (uuids, 0..) |uuid, row| {
        _ = buffer.writeText(buffer.area(), 0, @intCast(row), "/tmp/pi-clipboard-" ++ uuid.* ++ ".jpg", .{});
    }

    var found: [2]Marker = undefined;
    const count = collect(&buffer, &found);

    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqualStrings(uuids[1], &found[0].uuid);
    try testing.expectEqualStrings(uuids[2], &found[1].uuid);
}

test "the cursor is the hardware cursor or Pi's isolated inverse cell" {
    var buffer = try ui.Buffer.init(testing.allocator, 20, 2);
    defer buffer.deinit();
    _ = buffer.writeText(buffer.area(), 0, 0, "abc", .{});
    buffer.setCell(.{ .x = 3, .y = 0 }, .{ .text = " ", .width = 1, .style = .{ .flags = .{ .inverse = true } } });
    _ = buffer.writeText(buffer.area(), 0, 1, "sel", .{ .flags = .{ .inverse = true } });

    const hidden: Screen = .{ .buffer = &buffer, .cursor = .{ .visible = false, .x = 0, .y = 0 } };
    try testing.expect(cursorAt(hidden, .{ .x = 3, .y = 0 }));
    try testing.expect(!cursorAt(hidden, .{ .x = 1, .y = 1 }));
    try testing.expectEqual(@as(?u16, 3), cursorOnRow(hidden, 0));
    try testing.expect(cursorOnRow(hidden, 1) == null);

    const shown: Screen = .{ .buffer = &buffer, .cursor = .{ .visible = true, .x = 1, .y = 0 } };
    try testing.expect(cursorAt(shown, .{ .x = 1, .y = 0 }));
    try testing.expect(!cursorAt(shown, .{ .x = 3, .y = 0 }));
    try testing.expectEqual(@as(?u16, 1), cursorOnRow(shown, 0));
}

test "row steps count graphemes rather than cells" {
    var buffer = try ui.Buffer.init(testing.allocator, 20, 1);
    defer buffer.deinit();
    _ = buffer.writeText(buffer.area(), 0, 0, "a日b", .{});

    try testing.expectEqual(@as(?u8, 3), stepsOnRow(&buffer, 0, .{ .from = 0, .to = 4 }));
    try testing.expect(stepsOnRow(&buffer, 0, .{ .from = 4, .to = 0 }) == null);
}
