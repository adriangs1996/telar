//! Client-owned copy mode: cursor, selection, vim motions and frame
//! reconciliation. Everything here is pure over a cell buffer and a scroll
//! position; the client applies the returned effects.

const Point = @import("Point.zig");
const GranularityType = @import("telar-core").Granularity;
const Screen = @import("Screen.zig");
const PointType = @import("telar-core").Point;
const RangeType = @import("telar-core").Range;
const State = @import("State.zig");
const KeyType = @import("Key.zig");
const Effect = @import("Effect.zig");
const Viewport = @import("Viewport.zig");
const ScrollType = @import("telar-core").Scroll;
const BufferType = @import("telar-core").Buffer;
const std = @import("std");
const View = @import("CopyModeView.zig");
const chord = @import("chord.zig");
const SearchMatchType = @import("telar-core").SearchMatch;

pub const Direction = enum { forward, backward };

pub fn pointerSpan(point: Point, granularity: GranularityType, screen: Screen) [2]Point {
    const local: PointType = .{ .x = point.x, .y = @intCast(point.y - screen.scroll.offset) };
    var range = (RangeType{
        .anchor = local,
        .head = local,
        .granularity = granularity,
    }).expanded(screen.buffer);
    const row = screen.buffer.cells[@as(usize, local.y) * screen.buffer.w ..][0..screen.buffer.w];
    if (row[range.anchor.x].width == 0 and range.anchor.x > 0) {
        range.anchor.x -= 1;
    }

    if (row[range.head.x].width == 2 and range.head.x + 1 < screen.buffer.w) {
        range.head.x += 1;
    }

    return .{
        .{ .x = range.anchor.x, .y = screen.scroll.offset + range.anchor.y },
        .{ .x = range.head.x, .y = screen.scroll.offset + range.head.y },
    };
}

pub fn less(a: Point, b: Point) bool {
    return a.y < b.y or (a.y == b.y and a.x < b.x);
}

/// Interprets one key over the pane's visible cells. Pure: the only mutation
/// is the copy-mode state itself.
pub fn applyKey(state: *State, pressed: KeyType, screen: Screen) Effect {
    const buffer = screen.buffer;
    const scroll = screen.scroll;
    const page: i32 = @intCast(@max(@as(u16, 1), buffer.h -| 1));
    const viewport: Viewport = .{ .scroll = scroll, .rows = buffer.h };

    switch (pressed.code) {
        .escape => if (!state.clearSelection()) return .{ .exit = true },
        .enter => return .{ .exit = true, .copy = true },
        .left => state.horizontal(-1, buffer.w),
        .right => state.horizontal(1, buffer.w),
        .up => state.vertical(-1, viewport),
        .down => state.vertical(1, viewport),
        .home => state.lineStart(),
        .end => lastNonBlank(state, buffer, scroll),
        .page_up => state.vertical(-page, viewport),
        .page_down => state.vertical(page, viewport),
        .char => |char| if (pressed.mods.ctrl) {
            if (char.eql("b")) {
                state.vertical(-page, viewport);
            } else if (char.eql("f")) {
                state.vertical(page, viewport);
            } else if (char.eql("u")) {
                state.vertical(-@divTrunc(page, 2), viewport);
            } else if (char.eql("d")) {
                state.vertical(@divTrunc(page, 2), viewport);
            } else {
                return .{ .handled = false };
            }
        } else if (char.eql("h")) {
            state.horizontal(-1, buffer.w);
        } else if (char.eql("j")) {
            state.vertical(1, viewport);
        } else if (char.eql("k")) {
            state.vertical(-1, viewport);
        } else if (char.eql("l")) {
            state.horizontal(1, buffer.w);
        } else if (char.eql("0")) {
            state.lineStart();
        } else if (char.eql("^")) {
            firstNonBlank(state, buffer, scroll);
        } else if (char.eql("$")) {
            lastNonBlank(state, buffer, scroll);
        } else if (char.eql("w")) {
            wordForward(state, screen, false);
        } else if (char.eql("e")) {
            wordForward(state, screen, true);
        } else if (char.eql("b")) {
            wordBackward(state, buffer, scroll);
        } else if (char.eql("{")) {
            paragraph(state, screen, -1);
        } else if (char.eql("}")) {
            paragraph(state, screen, 1);
        } else if (char.eql("g")) {
            state.top();
        } else if (char.eql("G")) {
            state.bottom(scroll, buffer.h);
        } else if (char.eql("/")) {
            state.search_direction = .forward;
            return .{ .search = .forward };
        } else if (char.eql("?")) {
            state.search_direction = .backward;
            return .{ .search = .backward };
        } else if (char.eql("n")) {
            state.cycleMatch(if (state.search_direction == .forward) 1 else -1, viewport);
        } else if (char.eql("N")) {
            state.cycleMatch(if (state.search_direction == .forward) -1 else 1, viewport);
        } else if (char.eql("o")) {
            return .{ .open_link = true };
        } else if (char.eql("v") or char.eql(" ")) {
            state.toggleSelection(false);
        } else if (char.eql("V")) {
            state.toggleSelection(true);
        } else if (char.eql("y")) {
            return .{ .exit = true, .copy = true };
        } else if (char.eql("q")) {
            return .{ .exit = true };
        } else {
            return .{ .handled = false };
        },
        else => return .{ .handled = false },
    }
    return .{};
}

/// Reconciles the copy cursor with a runtime frame. Pruned scrollback pulls
/// the cursor and anchor up with it while the viewport sat at the pruned
/// edge; both are then clamped to the new history length.
pub fn onFrame(state: *State, previous_offset: u32, scroll: ScrollType) void {
    if (scroll.offset < previous_offset and state.viewport_offset == previous_offset) {
        const pruned = previous_offset - scroll.offset;
        state.cursor.y -|= pruned;
        if (state.pointer) |*pointer| {
            pointer.start.y -|= pruned;
            pointer.end.y -|= pruned;
        }

        if (state.anchor) |*anchor| {
            anchor.y -|= pruned;
        }
    }
    state.cursor.y = @min(state.cursor.y, scroll.total_rows -| 1);
    if (state.pointer) |*pointer| {
        pointer.start.y = @min(pointer.start.y, scroll.total_rows -| 1);
        pointer.end.y = @min(pointer.end.y, scroll.total_rows -| 1);
    }

    if (state.anchor) |*anchor| {
        anchor.y = @min(anchor.y, scroll.total_rows -| 1);
    }
    state.viewport_offset = scroll.offset;
}

const WordClass = enum { space, word, punctuation };

fn rowIndex(buffer: *const BufferType, scroll: ScrollType, absolute_y: u32) ?u16 {
    if (absolute_y < scroll.offset or absolute_y >= scroll.offset + buffer.h) {
        return null;
    }
    return @intCast(absolute_y - scroll.offset);
}

fn firstNonBlank(state: *State, buffer: *const BufferType, scroll: ScrollType) void {
    const row = rowIndex(buffer, scroll, state.cursor.y) orelse return state.lineStart();
    var x: u16 = 0;
    while (x < buffer.w) : (x += 1) {
        const text = buffer.cells[@as(usize, row) * buffer.w + x].text();
        if (text.len != 0 and !std.ascii.isWhitespace(text[0])) {
            break;
        }
    }
    state.cursor.x = @min(x, buffer.w -| 1);
}

fn lastNonBlank(state: *State, buffer: *const BufferType, scroll: ScrollType) void {
    const row = rowIndex(buffer, scroll, state.cursor.y) orelse return state.lineEnd(buffer.w);
    var x = buffer.w;
    while (x != 0) {
        x -= 1;
        const text = buffer.cells[@as(usize, row) * buffer.w + x].text();
        if (text.len != 0 and !std.ascii.isWhitespace(text[0])) {
            break;
        }
    }
    state.cursor.x = x;
}

fn paragraph(state: *State, screen: Screen, direction: i32) void {
    const buffer = screen.buffer;
    const scroll = screen.scroll;
    var y = state.cursor.y;
    while (true) {
        const next = if (direction < 0) y -| 1 else @min(y +| 1, scroll.total_rows -| 1);
        if (next == y) {
            break;
        }
        y = next;
        const row = rowIndex(buffer, scroll, y) orelse break;
        var blank = true;
        for (buffer.cells[@as(usize, row) * buffer.w ..][0..buffer.w]) |cell| {
            const text = cell.text();
            if (text.len != 0 and !std.ascii.isWhitespace(text[0])) {
                blank = false;
                break;
            }
        }
        if (blank) {
            break;
        }
    }
    state.cursor.y = y;
    state.cursor.x = 0;
    state.vertical(0, .{ .scroll = scroll, .rows = buffer.h });
}

fn wordClass(buffer: *const BufferType, scroll: ScrollType, point: Point) ?WordClass {
    const row = rowIndex(buffer, scroll, point.y) orelse return null;
    const cell = buffer.cells[@as(usize, row) * buffer.w + point.x];
    const text = cell.text();
    if (text.len == 0 or std.ascii.isWhitespace(text[0])) {
        return .space;
    }
    return if (std.ascii.isAlphanumeric(text[0]) or text[0] == '_')
        .word
    else
        .punctuation;
}

fn nextPoint(point: Point, cols: u16, total_rows: u32) Point {
    if (point.x + 1 < cols) {
        return .{ .x = point.x + 1, .y = point.y };
    }
    if (point.y + 1 < total_rows) {
        return .{ .x = 0, .y = point.y + 1 };
    }
    return point;
}

fn previousPoint(point: Point, cols: u16) Point {
    if (point.x != 0) {
        return .{ .x = point.x - 1, .y = point.y };
    }
    if (point.y != 0) {
        return .{ .x = cols - 1, .y = point.y - 1 };
    }
    return point;
}

fn wordForward(state: *State, screen: Screen, end: bool) void {
    const buffer = screen.buffer;
    const scroll = screen.scroll;
    const initial = wordClass(buffer, scroll, state.cursor) orelse {
        state.vertical(1, .{ .scroll = scroll, .rows = buffer.h });
        state.lineStart();
        return;
    };
    var point = state.cursor;
    if (end and initial != .space) {
        while (true) {
            const next = nextPoint(point, buffer.w, scroll.total_rows);
            if (std.meta.eql(next, point) or wordClass(buffer, scroll, next) != initial) {
                break;
            }
            point = next;
        }
    } else {
        while (wordClass(buffer, scroll, point)) |class| {
            if (class != initial) {
                break;
            }
            const next = nextPoint(point, buffer.w, scroll.total_rows);
            if (std.meta.eql(next, point)) {
                break;
            }
            point = next;
        }
        while (wordClass(buffer, scroll, point) == .space) {
            const next = nextPoint(point, buffer.w, scroll.total_rows);
            if (std.meta.eql(next, point)) {
                break;
            }
            point = next;
        }
        if (end) {
            const class = wordClass(buffer, scroll, point) orelse .space;
            while (true) {
                const next = nextPoint(point, buffer.w, scroll.total_rows);
                if (std.meta.eql(next, point) or wordClass(buffer, scroll, next) != class) {
                    break;
                }
                point = next;
            }
        }
    }
    state.cursor = point;
    state.vertical(0, .{ .scroll = scroll, .rows = buffer.h });
}

fn wordBackward(state: *State, buffer: *const BufferType, scroll: ScrollType) void {
    var point = previousPoint(state.cursor, buffer.w);
    while (wordClass(buffer, scroll, point) == .space) {
        const previous = previousPoint(point, buffer.w);
        if (std.meta.eql(previous, point)) {
            break;
        }
        point = previous;
    }
    const class = wordClass(buffer, scroll, point) orelse {
        state.vertical(-1, .{ .scroll = scroll, .rows = buffer.h });
        state.lineStart();
        return;
    };
    while (true) {
        const previous = previousPoint(point, buffer.w);
        if (std.meta.eql(previous, point) or wordClass(buffer, scroll, previous) != class) {
            break;
        }
        point = previous;
    }
    state.cursor = point;
    state.vertical(0, .{ .scroll = scroll, .rows = buffer.h });
}

test "vertical movement scrolls the viewport only at its edges" {
    const scroll: ScrollType = .{ .total_rows = 100, .offset = 90 };
    var state = State.init(@enumFromInt(1), .{ .x = 2, .y = 99 }, 90);
    state.vertical(-1, .{ .scroll = scroll, .rows = 10 });
    try std.testing.expectEqual(@as(u32, 90), state.viewport_offset);
    state.vertical(-20, .{ .scroll = scroll, .rows = 10 });
    try std.testing.expectEqual(@as(u32, 78), state.cursor.y);
    try std.testing.expectEqual(@as(u32, 78), state.viewport_offset);
}

test "pointer selection includes both cells of wide glyphs without copying a bare click" {
    var buffer = try BufferType.init(std.testing.allocator, 10, 2);
    defer buffer.deinit();
    buffer.fill(buffer.area(), .{ .glyph = " ", .style = .{} });
    _ = buffer.writeText(buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "a界b", .style = .{} });
    const screen: Screen = .{ .buffer = &buffer, .scroll = .{ .offset = 0, .total_rows = 2 } };
    var state = State.init(@enumFromInt(1), .{ .x = 2, .y = 0 }, 0);
    state.beginPointer(.character, screen);
    state.movePointer(.{ .position = .{ .x = 2, .y = 0 }, .release = true }, screen);
    try std.testing.expect(state.anchor == null);

    state.movePointer(.{ .position = .{ .x = 3, .y = 0 } }, screen);
    try std.testing.expectEqual(@as(u16, 1), state.anchor.?.x);
    try std.testing.expectEqual(@as(u16, 3), state.cursor.x);
    try std.testing.expect(state.view().selected(2, 0));
}

test "pointer word drags retain the original word when reversing direction" {
    var buffer = try BufferType.init(std.testing.allocator, 13, 2);
    defer buffer.deinit();
    buffer.fill(buffer.area(), .{ .glyph = " ", .style = .{} });
    _ = buffer.writeText(buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "one two three", .style = .{} });
    const screen: Screen = .{ .buffer = &buffer, .scroll = .{ .offset = 100, .total_rows = 102 } };
    var state = State.init(@enumFromInt(1), .{ .x = 5, .y = 100 }, 100);
    state.beginPointer(.word, screen);
    state.movePointer(.{ .position = .{ .x = 10, .y = 0 } }, screen);
    try std.testing.expectEqualDeep(Point{ .x = 4, .y = 100 }, state.anchor.?);
    try std.testing.expectEqualDeep(Point{ .x = 12, .y = 100 }, state.cursor);

    state.movePointer(.{ .position = .{ .x = 1, .y = 0 } }, screen);
    try std.testing.expectEqualDeep(Point{ .x = 6, .y = 100 }, state.anchor.?);
    try std.testing.expectEqualDeep(Point{ .x = 0, .y = 100 }, state.cursor);
    state.movePointer(.{ .position = .{ .x = 65535, .y = 65535 } }, screen);
    try std.testing.expectEqualDeep(Point{ .x = 12, .y = 101 }, state.cursor);
}

test "pruned history moves the captured pointer origin with its highlight" {
    var buffer = try BufferType.init(std.testing.allocator, 10, 2);
    defer buffer.deinit();
    var state = State.init(@enumFromInt(1), .{ .x = 2, .y = 100 }, 100);
    state.beginPointer(.character, .{ .buffer = &buffer, .scroll = .{ .offset = 100, .total_rows = 102 } });
    const scroll: ScrollType = .{ .offset = 90, .total_rows = 92 };
    onFrame(&state, 100, scroll);
    state.movePointer(.{ .position = .{ .x = 4, .y = 0 } }, .{ .buffer = &buffer, .scroll = scroll });

    try std.testing.expectEqualDeep(Point{ .x = 2, .y = 90 }, state.anchor.?);
    try std.testing.expectEqualDeep(Point{ .x = 4, .y = 90 }, state.cursor);
}

test "linear and linewise selections are inclusive" {
    const linear: View = .{
        .anchor = .{ .x = 3, .y = 4 },
        .cursor = .{ .x = 1, .y = 5 },
        .linewise = false,
    };
    try std.testing.expect(linear.selected(3, 4));
    try std.testing.expect(linear.selected(0, 5));
    try std.testing.expect(!linear.selected(2, 5));

    const linewise: View = .{
        .anchor = .{ .x = 3, .y = 4 },
        .cursor = .{ .x = 1, .y = 5 },
        .linewise = true,
    };
    try std.testing.expect(linewise.selected(99, 4));
    try std.testing.expect(linewise.selected(99, 5));
}

fn testScreen(gpa: std.mem.Allocator, rows: []const []const u8) !BufferType {
    var width: u16 = 0;
    for (rows) |row| width = @max(width, @as(u16, @intCast(row.len)));
    var buffer = try BufferType.init(gpa, width, @intCast(rows.len));
    buffer.fill(buffer.area(), .{ .glyph = " ", .style = .{} });
    for (rows, 0..) |row, y| _ = buffer.writeText(buffer.area(), .{ .point = .{ .x = 0, .y = @intCast(y) }, .text = row, .style = .{} });
    return buffer;
}

test "word motions travel by class over the visible cells" {
    const gpa = std.testing.allocator;
    var buffer = try testScreen(gpa, &.{ "foo bar,baz", "        end" });
    defer buffer.deinit();
    const scroll: ScrollType = .{ .total_rows = 2, .offset = 0 };
    var state = State.init(@enumFromInt(1), .{ .x = 0, .y = 0 }, 0);

    _ = applyKey(&state, try chord.parseKey("w"), .{ .buffer = &buffer, .scroll = scroll });
    try std.testing.expectEqual(@as(u16, 4), state.cursor.x);
    _ = applyKey(&state, try chord.parseKey("w"), .{ .buffer = &buffer, .scroll = scroll });
    try std.testing.expectEqual(@as(u16, 7), state.cursor.x);
    _ = applyKey(&state, try chord.parseKey("b"), .{ .buffer = &buffer, .scroll = scroll });
    try std.testing.expectEqual(@as(u16, 4), state.cursor.x);
    _ = applyKey(&state, try chord.parseKey("$"), .{ .buffer = &buffer, .scroll = scroll });
    try std.testing.expectEqual(@as(u16, 10), state.cursor.x);
    _ = applyKey(&state, try chord.parseKey("0"), .{ .buffer = &buffer, .scroll = scroll });
    try std.testing.expectEqual(@as(u16, 0), state.cursor.x);
}

test "escape clears the selection before it exits" {
    const gpa = std.testing.allocator;
    var buffer = try testScreen(gpa, &.{"abc"});
    defer buffer.deinit();
    const scroll: ScrollType = .{ .total_rows = 1, .offset = 0 };
    var state = State.init(@enumFromInt(1), .{ .x = 0, .y = 0 }, 0);

    _ = applyKey(&state, try chord.parseKey("v"), .{ .buffer = &buffer, .scroll = scroll });
    try std.testing.expect(state.anchor != null);
    const cleared = applyKey(&state, try chord.parseKey("escape"), .{ .buffer = &buffer, .scroll = scroll });
    try std.testing.expect(!cleared.exit);
    try std.testing.expect(state.anchor == null);
    const exited = applyKey(&state, try chord.parseKey("escape"), .{ .buffer = &buffer, .scroll = scroll });
    try std.testing.expect(exited.exit and !exited.copy);
    const copied = applyKey(&state, try chord.parseKey("y"), .{ .buffer = &buffer, .scroll = scroll });
    try std.testing.expect(copied.exit and copied.copy);
    const ignored = applyKey(&state, try chord.parseKey("z"), .{ .buffer = &buffer, .scroll = scroll });
    try std.testing.expect(!ignored.handled);
}

test "a pruning frame pulls cursor and anchor up before clamping" {
    var state = State.init(@enumFromInt(1), .{ .x = 0, .y = 50 }, 40);
    state.anchor = .{ .x = 0, .y = 45 };

    // Ten rows pruned while the viewport sat at the pruned edge.
    onFrame(&state, 40, .{ .total_rows = 55, .offset = 30 });
    try std.testing.expectEqual(@as(u32, 40), state.cursor.y);
    try std.testing.expectEqual(@as(u32, 35), state.anchor.?.y);
    try std.testing.expectEqual(@as(u32, 30), state.viewport_offset);

    // A shrunken history clamps both; the viewport did not sit at the
    // pruned edge this time, so nothing is pulled up first.
    onFrame(&state, 99, .{ .total_rows = 20, .offset = 0 });
    try std.testing.expectEqual(@as(u32, 19), state.cursor.y);
    try std.testing.expectEqual(@as(u32, 19), state.anchor.?.y);
}

test "matches select relative to the cursor, highlight and cycle with wrap" {
    const scroll: ScrollType = .{ .total_rows = 40, .offset = 0 };
    var state = State.init(@enumFromInt(1), .{ .x = 0, .y = 10 }, 0);
    const results = [_]SearchMatchType{
        .{ .x = 2, .y = 4, .len = 3 },
        .{ .x = 1, .y = 12, .len = 2 },
        .{ .x = 5, .y = 30, .len = 4 },
    };

    state.applyMatches(&results, .{ .scroll = scroll, .rows = 5 });
    try std.testing.expectEqual(@as(u8, 1), state.match_index);
    try std.testing.expectEqualDeep(Point{ .x = 1, .y = 12 }, state.anchor.?);
    try std.testing.expectEqualDeep(Point{ .x = 2, .y = 12 }, state.cursor);

    state.cycleMatch(1, .{ .scroll = scroll, .rows = 5 });
    try std.testing.expectEqual(@as(u8, 2), state.match_index);
    state.cycleMatch(1, .{ .scroll = scroll, .rows = 5 });
    try std.testing.expectEqual(@as(u8, 0), state.match_index);
    try std.testing.expect(state.viewport_offset <= 4);

    state.search_direction = .backward;
    state.cursor = .{ .x = 0, .y = 10 };
    state.applyMatches(&results, .{ .scroll = scroll, .rows = 5 });
    try std.testing.expectEqual(@as(u8, 0), state.match_index);

    state.applyMatches(&.{}, .{ .scroll = scroll, .rows = 5 });
    try std.testing.expectEqual(@as(u8, 0), state.match_count);
}

test "slash and question mark ask for the search input" {
    var buffer = try BufferType.init(std.testing.allocator, 10, 5);
    defer buffer.deinit();
    const scroll: ScrollType = .{ .total_rows = 5, .offset = 0 };
    var state = State.init(@enumFromInt(1), .{ .x = 0, .y = 0 }, 0);

    const forward = applyKey(&state, .{ .code = .{ .char = .init("/") } }, .{ .buffer = &buffer, .scroll = scroll });
    try std.testing.expectEqual(Direction.forward, forward.search.?);
    const backward = applyKey(&state, .{ .code = .{ .char = .init("?") } }, .{ .buffer = &buffer, .scroll = scroll });
    try std.testing.expectEqual(Direction.backward, backward.search.?);
    try std.testing.expectEqual(Direction.backward, state.search_direction);
}

test "o asks the client to open the link under the cursor" {
    var buffer = try BufferType.init(std.testing.allocator, 10, 5);
    defer buffer.deinit();
    const scroll: ScrollType = .{ .total_rows = 5, .offset = 0 };
    var state = State.init(@enumFromInt(1), .{ .x = 0, .y = 0 }, 0);

    const effect = applyKey(&state, .{ .code = .{ .char = .init("o") } }, .{ .buffer = &buffer, .scroll = scroll });

    try std.testing.expect(effect.open_link);
    try std.testing.expect(!effect.exit);
}
