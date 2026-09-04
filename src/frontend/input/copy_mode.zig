//! Client-owned copy mode: cursor, selection, vim motions and frame
//! reconciliation. Everything here is pure over a cell buffer and a scroll
//! position; the client applies the returned effects.

const std = @import("std");
const core = @import("telar-core");
const keybind = @import("keybind.zig");

const schema = core.schema;
const ui = core.ui;

pub const Direction = enum { forward, backward };

pub const max_matches = core.schema.max_search_matches;

pub const Point = struct {
    x: u16,
    /// Absolute row from the beginning of the retained screen history.
    y: u32,
};

pub const Viewport = struct {
    scroll: schema.frame.Scroll,
    rows: u16,
};

pub const Screen = struct {
    buffer: *const ui.Buffer,
    scroll: schema.frame.Scroll,
};

pub const View = struct {
    cursor: Point,
    anchor: ?Point,
    linewise: bool,

    pub fn selected(view: View, x: u16, y: u32) bool {
        const anchor = view.anchor orelse return false;
        if (view.linewise) {
            const first = @min(anchor.y, view.cursor.y);
            const last = @max(anchor.y, view.cursor.y);
            return y >= first and y <= last;
        }
        const point = Point{ .x = x, .y = y };
        const first, const last = if (less(view.cursor, anchor))
            .{ view.cursor, anchor }
        else
            .{ anchor, view.cursor };
        return !less(point, first) and !less(last, point);
    }
};

pub const State = struct {
    pane_id: schema.PaneId,
    cursor: Point,
    anchor: ?Point = null,
    linewise: bool = false,
    entry_offset: u32,
    viewport_offset: u32,
    search_direction: Direction = .forward,
    matches: [max_matches]schema.SearchMatch = @splat(.{ .x = 0, .y = 0, .len = 0 }),
    match_count: u8 = 0,
    match_index: u8 = 0,

    pub fn init(pane_id: schema.PaneId, cursor: Point, viewport_offset: u32) State {
        return .{
            .pane_id = pane_id,
            .cursor = cursor,
            .entry_offset = viewport_offset,
            .viewport_offset = viewport_offset,
        };
    }

    pub fn view(state: State) View {
        return .{
            .cursor = state.cursor,
            .anchor = state.anchor,
            .linewise = state.linewise,
        };
    }

    pub fn toggleSelection(state: *State, linewise: bool) void {
        if (state.anchor != null and state.linewise == linewise) {
            state.anchor = null;
            state.linewise = false;
            return;
        }
        state.anchor = state.cursor;
        state.linewise = linewise;
    }

    pub fn clearSelection(state: *State) bool {
        if (state.anchor == null) {
            return false;
        }
        state.anchor = null;
        state.linewise = false;
        return true;
    }

    pub fn horizontal(state: *State, delta: i32, cols: u16) void {
        if (delta < 0) {
            state.cursor.x -|= @intCast(-delta);
        } else {
            state.cursor.x = @min(cols -| 1, state.cursor.x +| @as(u16, @intCast(delta)));
        }
    }

    pub fn vertical(state: *State, delta: i32, viewport: Viewport) void {
        const last = viewport.scroll.total_rows -| 1;
        if (delta < 0) {
            state.cursor.y -|= @intCast(-delta);
        } else {
            state.cursor.y = @min(last, state.cursor.y +| @as(u32, @intCast(delta)));
        }
        state.reveal(viewport.rows, viewport.scroll);
    }

    pub fn top(state: *State) void {
        state.cursor.y = 0;
        state.viewport_offset = 0;
    }

    pub fn bottom(state: *State, scroll: schema.frame.Scroll, rows: u16) void {
        state.cursor.y = scroll.total_rows -| 1;
        state.viewport_offset = scroll.maxOffset(rows);
    }

    pub fn lineStart(state: *State) void {
        state.cursor.x = 0;
    }

    pub fn lineEnd(state: *State, cols: u16) void {
        state.cursor.x = cols -| 1;
    }

    /// Stores search results and selects the first match at or after the
    /// cursor (forward) or before it (backward). The current match becomes
    /// the selection so it is visibly highlighted.
    ///
    /// ```zig
    /// state.applyMatches(results, viewport);
    /// ```
    pub fn applyMatches(state: *State, results: []const schema.SearchMatch, viewport: Viewport) void {
        state.match_count = @intCast(@min(results.len, state.matches.len));
        @memcpy(state.matches[0..state.match_count], results[0..state.match_count]);
        if (state.match_count == 0) {
            return;
        }

        var selected: ?u8 = null;
        switch (state.search_direction) {
            .forward => {
                for (state.matchSlice(), 0..) |match, index| {
                    if (less(state.cursor, .{ .x = match.x, .y = match.y })) {
                        selected = @intCast(index);
                        break;
                    }
                }
            },
            .backward => {
                var index: usize = state.match_count;
                while (index > 0) {
                    index -= 1;
                    const match = state.matches[index];
                    if (less(.{ .x = match.x, .y = match.y }, state.cursor)) {
                        selected = @intCast(index);
                        break;
                    }
                }
            },
        }

        state.gotoMatch(selected orelse switch (state.search_direction) {
            .forward => 0,
            .backward => state.match_count - 1,
        }, viewport);
    }

    /// Moves to the next or previous stored match, wrapping around.
    ///
    /// ```zig
    /// state.cycleMatch(1, viewport);
    /// ```
    pub fn cycleMatch(state: *State, delta: i2, viewport: Viewport) void {
        if (state.match_count == 0) {
            return;
        }

        const count: i16 = state.match_count;
        var index: i16 = state.match_index;
        index = @mod(index + delta, count);
        state.gotoMatch(@intCast(index), viewport);
    }

    pub fn matchSlice(state: *const State) []const schema.SearchMatch {
        return state.matches[0..state.match_count];
    }

    fn gotoMatch(state: *State, index: u8, viewport: Viewport) void {
        const match = state.matches[index];
        state.match_index = index;
        state.anchor = .{ .x = match.x, .y = match.y };
        state.linewise = false;
        state.cursor = .{ .x = match.x + match.len - 1, .y = match.y };
        state.cursor.y = @min(state.cursor.y, viewport.scroll.total_rows -| 1);
        state.reveal(viewport.rows, viewport.scroll);
    }

    fn reveal(state: *State, rows: u16, scroll: schema.frame.Scroll) void {
        if (state.cursor.y < state.viewport_offset) {
            state.viewport_offset = state.cursor.y;
        } else if (state.cursor.y >= state.viewport_offset + rows) {
            state.viewport_offset = state.cursor.y - rows + 1;
        }
        state.viewport_offset = @min(state.viewport_offset, scroll.maxOffset(rows));
    }
};

fn less(a: Point, b: Point) bool {
    return a.y < b.y or (a.y == b.y and a.x < b.x);
}

/// What one handled key asks the client to do. Cursor, selection and
/// viewport changes already happened inside the state; the client only
/// projects them and, on exit, copies the selection.
pub const Effect = struct {
    handled: bool = true,
    exit: bool = false,
    copy: bool = false,
    /// Ask the client to open the search input in this direction.
    search: ?Direction = null,
    /// Ask the client to open the textual link under the copy cursor.
    open_link: bool = false,
};

/// Interprets one key over the pane's visible cells. Pure: the only mutation
/// is the copy-mode state itself.
pub fn applyKey(state: *State, pressed: keybind.Key, screen: Screen) Effect {
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
            wordForward(state, buffer, scroll, false);
        } else if (char.eql("e")) {
            wordForward(state, buffer, scroll, true);
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
pub fn onFrame(state: *State, previous_offset: u32, scroll: schema.frame.Scroll) void {
    if (scroll.offset < previous_offset and state.viewport_offset == previous_offset) {
        const pruned = previous_offset - scroll.offset;
        state.cursor.y -|= pruned;
        if (state.anchor) |*anchor| {
            anchor.y -|= pruned;
        }
    }
    state.cursor.y = @min(state.cursor.y, scroll.total_rows -| 1);
    if (state.anchor) |*anchor| {
        anchor.y = @min(anchor.y, scroll.total_rows -| 1);
    }
    state.viewport_offset = scroll.offset;
}

const WordClass = enum { space, word, punctuation };

fn rowIndex(buffer: *const ui.Buffer, scroll: schema.frame.Scroll, absolute_y: u32) ?u16 {
    if (absolute_y < scroll.offset or absolute_y >= scroll.offset + buffer.h) {
        return null;
    }
    return @intCast(absolute_y - scroll.offset);
}

fn firstNonBlank(state: *State, buffer: *const ui.Buffer, scroll: schema.frame.Scroll) void {
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

fn lastNonBlank(state: *State, buffer: *const ui.Buffer, scroll: schema.frame.Scroll) void {
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

fn wordClass(buffer: *const ui.Buffer, scroll: schema.frame.Scroll, point: Point) ?WordClass {
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

fn wordForward(state: *State, buffer: *const ui.Buffer, scroll: schema.frame.Scroll, end: bool) void {
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

fn wordBackward(state: *State, buffer: *const ui.Buffer, scroll: schema.frame.Scroll) void {
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
    const scroll: schema.frame.Scroll = .{ .total_rows = 100, .offset = 90 };
    var state = State.init(@enumFromInt(1), .{ .x = 2, .y = 99 }, 90);
    state.vertical(-1, .{ .scroll = scroll, .rows = 10 });
    try std.testing.expectEqual(@as(u32, 90), state.viewport_offset);
    state.vertical(-20, .{ .scroll = scroll, .rows = 10 });
    try std.testing.expectEqual(@as(u32, 78), state.cursor.y);
    try std.testing.expectEqual(@as(u32, 78), state.viewport_offset);
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

fn testScreen(gpa: std.mem.Allocator, rows: []const []const u8) !ui.Buffer {
    var width: u16 = 0;
    for (rows) |row| width = @max(width, @as(u16, @intCast(row.len)));
    var buffer = try ui.Buffer.init(gpa, width, @intCast(rows.len));
    buffer.fill(buffer.area(), .{ .glyph = " ", .style = .{} });
    for (rows, 0..) |row, y| _ = buffer.writeText(buffer.area(), .{ .point = .{ .x = 0, .y = @intCast(y) }, .text = row, .style = .{} });
    return buffer;
}

test "word motions travel by class over the visible cells" {
    const gpa = std.testing.allocator;
    var buffer = try testScreen(gpa, &.{ "foo bar,baz", "        end" });
    defer buffer.deinit();
    const scroll: schema.frame.Scroll = .{ .total_rows = 2, .offset = 0 };
    var state = State.init(@enumFromInt(1), .{ .x = 0, .y = 0 }, 0);

    _ = applyKey(&state, try keybind.parseKey("w"), .{ .buffer = &buffer, .scroll = scroll });
    try std.testing.expectEqual(@as(u16, 4), state.cursor.x);
    _ = applyKey(&state, try keybind.parseKey("w"), .{ .buffer = &buffer, .scroll = scroll });
    try std.testing.expectEqual(@as(u16, 7), state.cursor.x);
    _ = applyKey(&state, try keybind.parseKey("b"), .{ .buffer = &buffer, .scroll = scroll });
    try std.testing.expectEqual(@as(u16, 4), state.cursor.x);
    _ = applyKey(&state, try keybind.parseKey("$"), .{ .buffer = &buffer, .scroll = scroll });
    try std.testing.expectEqual(@as(u16, 10), state.cursor.x);
    _ = applyKey(&state, try keybind.parseKey("0"), .{ .buffer = &buffer, .scroll = scroll });
    try std.testing.expectEqual(@as(u16, 0), state.cursor.x);
}

test "escape clears the selection before it exits" {
    const gpa = std.testing.allocator;
    var buffer = try testScreen(gpa, &.{"abc"});
    defer buffer.deinit();
    const scroll: schema.frame.Scroll = .{ .total_rows = 1, .offset = 0 };
    var state = State.init(@enumFromInt(1), .{ .x = 0, .y = 0 }, 0);

    _ = applyKey(&state, try keybind.parseKey("v"), .{ .buffer = &buffer, .scroll = scroll });
    try std.testing.expect(state.anchor != null);
    const cleared = applyKey(&state, try keybind.parseKey("escape"), .{ .buffer = &buffer, .scroll = scroll });
    try std.testing.expect(!cleared.exit);
    try std.testing.expect(state.anchor == null);
    const exited = applyKey(&state, try keybind.parseKey("escape"), .{ .buffer = &buffer, .scroll = scroll });
    try std.testing.expect(exited.exit and !exited.copy);
    const copied = applyKey(&state, try keybind.parseKey("y"), .{ .buffer = &buffer, .scroll = scroll });
    try std.testing.expect(copied.exit and copied.copy);
    const ignored = applyKey(&state, try keybind.parseKey("z"), .{ .buffer = &buffer, .scroll = scroll });
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
    const scroll: schema.frame.Scroll = .{ .total_rows = 40, .offset = 0 };
    var state = State.init(@enumFromInt(1), .{ .x = 0, .y = 10 }, 0);
    const results = [_]schema.SearchMatch{
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
    var buffer = try ui.Buffer.init(std.testing.allocator, 10, 5);
    defer buffer.deinit();
    const scroll: schema.frame.Scroll = .{ .total_rows = 5, .offset = 0 };
    var state = State.init(@enumFromInt(1), .{ .x = 0, .y = 0 }, 0);

    const forward = applyKey(&state, .{ .code = .{ .char = .init("/") } }, .{ .buffer = &buffer, .scroll = scroll });
    try std.testing.expectEqual(Direction.forward, forward.search.?);
    const backward = applyKey(&state, .{ .code = .{ .char = .init("?") } }, .{ .buffer = &buffer, .scroll = scroll });
    try std.testing.expectEqual(Direction.backward, backward.search.?);
    try std.testing.expectEqual(Direction.backward, state.search_direction);
}

test "o asks the client to open the link under the cursor" {
    var buffer = try ui.Buffer.init(std.testing.allocator, 10, 5);
    defer buffer.deinit();
    const scroll: schema.frame.Scroll = .{ .total_rows = 5, .offset = 0 };
    var state = State.init(@enumFromInt(1), .{ .x = 0, .y = 0 }, 0);

    const effect = applyKey(&state, .{ .code = .{ .char = .init("o") } }, .{ .buffer = &buffer, .scroll = scroll });

    try std.testing.expect(effect.open_link);
    try std.testing.expect(!effect.exit);
}
