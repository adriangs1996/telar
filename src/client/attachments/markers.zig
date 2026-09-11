//! Pure marker scanning and editor-navigation plans over committed cells.

const MarkerScreen = @import("MarkerScreen.zig");
const MarkerRemoval = @import("MarkerRemoval.zig");
const path_marker = @import("path_marker.zig");
const types = @import("types.zig");
const MarkerType = @import("Marker.zig");
const ScreenType = @import("Screen.zig");
const BufferType = @import("telar-core").Buffer;
const CursorType = @import("telar-core").Cursor;
const MarkerPosition = @import("MarkerPosition.zig");
const std = @import("std");
const MarkerScan = @import("MarkerScan.zig");
const MarkerBoundary = @import("MarkerBoundary.zig");
const PointType = @import("telar-core").Point;
const MarkerTail = @import("MarkerTail.zig");
const CellType = @import("telar-core").Cell;
const SpanType = @import("Span.zig");

const marker_head = "[Image";
pub const marker_head_width: u16 = marker_head.len;
const marker_separator = " #";
const marker_separator_width: u16 = marker_separator.len;
pub const minimum_marker_width: u16 = marker_head_width + marker_separator_width + 2;

/// The cursor must share a row with the marker's end or start. A wrapped
/// marker spans two rows, and steps across the wrap cannot be counted from
/// cells alone.
pub fn planPlaceholderRemoval(number: ?u16, ordinal: u8, screen: MarkerScreen) ?MarkerRemoval {
    const marker_number = number orelse @as(u16, ordinal) + 1;
    if (!screen.cursor.visible) {
        return null;
    }

    const marker = findMarker(screen.buffer, marker_number, screen.cursor) orelse return null;
    const cursor = screen.cursor;
    if (cursor.y == marker.end.y and cursor.x >= marker.end.x) {
        const steps = atomicSteps(screen.buffer, marker.end.y, .{
            .from = marker.end.x,
            .to = cursor.x,
        }) orelse return null;

        return .{ .direction = .left, .steps = steps, .deletion = .backward };
    }

    if (cursor.y == marker.start.y and cursor.x <= marker.start.x) {
        const steps = atomicSteps(screen.buffer, marker.start.y, .{
            .from = cursor.x,
            .to = marker.start.x,
        }) orelse return null;

        return .{ .direction = .right, .steps = steps, .deletion = .forward };
    }

    return null;
}

/// Pi's cursor must share a row with the path's end or start; steps across a
/// wrapped row cannot be counted from cells alone.
pub fn planPathRemoval(path: ?path_marker.Uuid, screen: MarkerScreen) ?MarkerRemoval {
    const uuid = path orelse return null;
    const marker = path_marker.find(screen.buffer, uuid) orelse return null;
    const cells = marker.cells orelse return null;
    const path_screen = pathScreen(screen);
    if (path_marker.cursorOnRow(path_screen, marker.end.y)) |cursor_x| {
        if (cursor_x >= marker.end.x) {
            const steps = path_marker.stepsOnRow(screen.buffer, marker.end.y, .{
                .from = marker.end.x,
                .to = cursor_x,
            }) orelse return null;

            return .{ .direction = .left, .steps = steps, .deletion = .backward, .deletions = cells };
        }
    }
    if (path_marker.cursorOnRow(path_screen, marker.start.y)) |cursor_x| {
        if (cursor_x <= marker.start.x) {
            const steps = path_marker.stepsOnRow(screen.buffer, marker.start.y, .{
                .from = cursor_x,
                .to = marker.start.x,
            }) orelse return null;

            return .{ .direction = .right, .steps = steps, .deletion = .forward, .deletions = cells };
        }
    }

    return null;
}

pub fn pathTouchesCursor(uuid: path_marker.Uuid, screen: MarkerScreen, deletion: types.MarkerDeletion) bool {
    const marker = path_marker.find(screen.buffer, uuid) orelse return false;

    return markerCursorTouches(marker, screen, deletion);
}

pub fn markerCursorTouches(marker: MarkerType, screen: MarkerScreen, deletion: types.MarkerDeletion) bool {
    return switch (deletion) {
        .backward => path_marker.cursorAt(pathScreen(screen), marker.end),
        .forward => path_marker.cursorAt(pathScreen(screen), marker.start),
    };
}

pub fn pathScreen(screen: MarkerScreen) ScreenType {
    return .{ .buffer = screen.buffer, .cursor = screen.cursor };
}

/// Pairs the oldest unpaired Pi preview with the oldest unclaimed path among
/// the newest ones on screen, mirroring how Claude's numbers are paired.
/// Picks the marker carrying `number` closest to the cursor. The transcript
/// above the prompt may repeat a sent prompt's markers.
pub fn findMarker(buffer: *const BufferType, number: u16, cursor: CursorType) ?MarkerPosition {
    var best: ?MarkerPosition = null;
    var best_distance: u32 = std.math.maxInt(u32);
    var scan: MarkerScan = .{ .buffer = buffer };
    while (scan.next()) |candidate| {
        if (candidate.number != number) {
            continue;
        }

        const row_distance = if (candidate.end.y > cursor.y) candidate.end.y - cursor.y else cursor.y - candidate.end.y;
        const column_distance = if (candidate.end.x > cursor.x) candidate.end.x - cursor.x else cursor.x - candidate.end.x;
        const distance = @as(u32, row_distance) * (@as(u32, buffer.w) + 1) + column_distance;
        if (distance < best_distance) {
            best = candidate;
            best_distance = distance;
        }
    }

    return best;
}

pub fn markerPresent(buffer: *const BufferType, number: u16) bool {
    var scan: MarkerScan = .{ .buffer = buffer };
    while (scan.next()) |marker| {
        if (marker.number == number) {
            return true;
        }
    }

    return false;
}

pub fn markerTouchesCursor(buffer: *const BufferType, boundary: MarkerBoundary) bool {
    const cursor: PointType = .{ .x = boundary.cursor.x, .y = boundary.cursor.y };
    var scan: MarkerScan = .{ .buffer = buffer };
    while (scan.next()) |marker| {
        if (marker.number != boundary.ordinal) {
            continue;
        }

        const edge = switch (boundary.deletion) {
            .backward => marker.end,
            .forward => marker.start,
        };
        if (std.meta.eql(edge, cursor)) {
            return true;
        }
    }

    return false;
}

/// Reads one `[Image #N]` placeholder whose head starts at `at`. The editor
/// may have wrapped the placeholder at its space: the head then closes its
/// row and `#N]` opens the next one after that row's indentation.
pub fn parseMarker(buffer: *const BufferType, at: PointType) ?MarkerPosition {
    if (!cellsMatch(buffer, at, marker_head)) {
        return null;
    }

    const after_head: PointType = .{ .x = at.x + marker_head_width, .y = at.y };
    if (cellsMatch(buffer, after_head, marker_separator)) {
        const tail = parseMarkerTail(buffer, .{ .x = after_head.x + marker_separator_width, .y = at.y }) orelse return null;

        return .{ .number = tail.number, .start = at, .end = tail.end };
    }

    if (at.y + 1 >= buffer.h or !rowBlankFrom(buffer, after_head)) {
        return null;
    }

    const number_x = firstInkOnRow(buffer, at.y + 1) orelse return null;
    const hash: PointType = .{ .x = number_x, .y = at.y + 1 };
    if (!cellsMatch(buffer, hash, "#")) {
        return null;
    }

    const tail = parseMarkerTail(buffer, .{ .x = hash.x + 1, .y = hash.y }) orelse return null;

    return .{ .number = tail.number, .start = at, .end = tail.end };
}

/// Reads the `N]` that closes a marker, starting at its first digit.
pub fn parseMarkerTail(buffer: *const BufferType, at: PointType) ?MarkerTail {
    var number: u16 = 0;
    var x = at.x;
    while (x < buffer.w) : (x += 1) {
        const cell = cellAt(buffer, .{ .x = x, .y = at.y });
        if (cell.width == 0 or cell.text().len != 1) {
            return null;
        }

        const byte = cell.text()[0];
        if (byte == ']') {
            if (x == at.x or number == 0) {
                return null;
            }

            return .{ .number = number, .end = .{ .x = x + 1, .y = at.y } };
        }
        if (byte < '0' or byte > '9') {
            return null;
        }

        number = std.math.mul(u16, number, 10) catch return null;
        number = std.math.add(u16, number, byte - '0') catch return null;
    }

    return null;
}

pub fn cellAt(buffer: *const BufferType, at: PointType) CellType {
    return buffer.cells[@as(usize, at.y) * buffer.w + at.x];
}

/// Reports whether `literal` occupies the cells starting at `at`, one ASCII
/// byte per single-width cell.
pub fn cellsMatch(buffer: *const BufferType, at: PointType, literal: []const u8) bool {
    if (at.y >= buffer.h or at.x + literal.len > buffer.w) {
        return false;
    }

    for (literal, 0..) |expected, offset| {
        const cell = cellAt(buffer, .{ .x = at.x + @as(u16, @intCast(offset)), .y = at.y });
        if (cell.width == 0 or cell.text().len != 1 or cell.text()[0] != expected) {
            return false;
        }
    }

    return true;
}

pub fn cellBlank(cell: CellType) bool {
    return cell.width == 0 or std.mem.eql(u8, cell.text(), " ");
}

pub fn rowBlankFrom(buffer: *const BufferType, at: PointType) bool {
    var x = at.x;
    while (x < buffer.w) : (x += 1) {
        if (!cellBlank(cellAt(buffer, .{ .x = x, .y = at.y }))) {
            return false;
        }
    }

    return true;
}

pub fn firstInkOnRow(buffer: *const BufferType, y: u16) ?u16 {
    var x: u16 = 0;
    while (x < buffer.w) : (x += 1) {
        if (!cellBlank(cellAt(buffer, .{ .x = x, .y = y }))) {
            return x;
        }
    }

    return null;
}

/// Width of the marker occupying one row from `x`, or 0 when the cell opens
/// no marker or the marker wraps onto the next row.
pub fn markerWidthAt(buffer: *const BufferType, x: u16, y: u16) u16 {
    const marker = parseMarker(buffer, .{ .x = x, .y = y }) orelse return 0;
    if (!marker.contiguous()) {
        return 0;
    }

    return marker.end.x - marker.start.x;
}

/// Reports whether the editor cursor follows a backslash. Claude and Pi
/// turn the Enter that follows one into a newline instead of a submission.
///
/// ```zig
/// if (attachments.promptContinuesAtCursor(screen)) return;
/// ```
pub fn promptContinuesAtCursor(screen: MarkerScreen) bool {
    const cursor = editorCursor(screen) orelse return false;
    if (cursor.x == 0) {
        return false;
    }

    return cellsMatch(screen.buffer, .{ .x = cursor.x - 1, .y = cursor.y }, "\\");
}

/// The hardware cursor when the child shows it, otherwise Pi's isolated
/// inverse-video cell.
pub fn editorCursor(screen: MarkerScreen) ?PointType {
    if (screen.cursor.visible) {
        return .{ .x = screen.cursor.x, .y = screen.cursor.y };
    }

    var y: u16 = 0;
    while (y < screen.buffer.h) : (y += 1) {
        if (path_marker.cursorOnRow(pathScreen(screen), y)) |x| {
            return .{ .x = x, .y = y };
        }
    }

    return null;
}

pub fn atomicSteps(buffer: *const BufferType, y: u16, span: SpanType) ?u8 {
    if (span.from > span.to or span.to > buffer.w) {
        return null;
    }

    var steps: u16 = 0;
    var x = span.from;
    while (x < span.to) {
        const width = markerWidthAt(buffer, x, y);
        if (width != 0 and x + width <= span.to) {
            steps += 1;
            x += width;
        } else {
            const cell = buffer.cells[@as(usize, y) * buffer.w + x];
            steps += @intFromBool(cell.width != 0);
            x += 1;
        }
        if (steps > types.max_marker_navigation_steps) {
            return null;
        }
    }

    return @intCast(steps);
}
