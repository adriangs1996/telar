const State = @This();
const source_namespace = @import("copy_mode.zig");
const Point = @import("Point.zig");
const PointerSelection = @import("PointerSelection.zig");
const View = @import("View.zig");
const core = @import("telar-core");
const Screen = @import("Screen.zig");
const PointerMotion = @import("PointerMotion.zig");
const std = @import("std");
const Viewport = @import("Viewport.zig");
pane_id: source_namespace.schema.PaneId,
cursor: Point,
pointer: ?PointerSelection = null,
anchor: ?Point = null,
linewise: bool = false,
entry_offset: u32,
viewport_offset: u32,
search_direction: source_namespace.Direction = .forward,
matches: [source_namespace.max_matches]source_namespace.schema.SearchMatch = @splat(.{ .x = 0, .y = 0, .len = 0 }),
match_count: u8 = 0,
match_index: u8 = 0,

pub fn init(pane_id: source_namespace.schema.PaneId, cursor: Point, viewport_offset: u32) State {
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
        .pointer = state.pointer != null,
        .anchor = state.anchor,
        .linewise = state.linewise,
    };
}

/// Captures a word or line boundary once; subsequent drags retain it.
/// Example: `state.beginPointer(.word, screen);`.
pub fn beginPointer(state: *State, granularity: core.select.Granularity, screen: Screen) void {
    const span = source_namespace.pointerSpan(state.cursor, granularity, screen);
    state.pointer = .{
        .start = span[0],
        .end = span[1],
        .granularity = granularity,
        .cols = screen.buffer.w,
        .rows = screen.buffer.h,
    };
    state.anchor = if (granularity == .character) null else span[0];
    state.cursor = span[1];
    state.linewise = granularity == .line;
}

/// Extends only within the supplied pane cells, in absolute history rows.
/// Example: `state.movePointer(motion, screen);`.
pub fn movePointer(state: *State, motion: PointerMotion, screen: Screen) void {
    const pointer = if (state.pointer) |*value| value else return;
    if (screen.buffer.w == 0 or screen.buffer.h == 0) {
        return;
    }

    const point: Point = .{
        .x = @min(motion.position.x, screen.buffer.w - 1),
        .y = screen.scroll.offset + @min(motion.position.y, screen.buffer.h - 1),
    };
    const span = source_namespace.pointerSpan(point, pointer.granularity, screen);
    const backwards = source_namespace.less(point, pointer.start);
    state.anchor = if (backwards) pointer.end else pointer.start;
    state.cursor = if (backwards) span[0] else span[1];
    if (pointer.granularity == .character and std.meta.eql(span[0], pointer.start) and std.meta.eql(span[1], pointer.end)) {
        state.anchor = null;
    }
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

pub fn bottom(state: *State, scroll: source_namespace.schema.frame.Scroll, rows: u16) void {
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
pub fn applyMatches(state: *State, results: []const source_namespace.schema.SearchMatch, viewport: Viewport) void {
    state.match_count = @intCast(@min(results.len, state.matches.len));
    @memcpy(state.matches[0..state.match_count], results[0..state.match_count]);
    if (state.match_count == 0) {
        return;
    }

    var selected: ?u8 = null;
    switch (state.search_direction) {
        .forward => {
            for (state.matchSlice(), 0..) |match, index| {
                if (source_namespace.less(state.cursor, .{ .x = match.x, .y = match.y })) {
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
                if (source_namespace.less(.{ .x = match.x, .y = match.y }, state.cursor)) {
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

pub fn matchSlice(state: *const State) []const source_namespace.schema.SearchMatch {
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

fn reveal(state: *State, rows: u16, scroll: source_namespace.schema.frame.Scroll) void {
    if (state.cursor.y < state.viewport_offset) {
        state.viewport_offset = state.cursor.y;
    } else if (state.cursor.y >= state.viewport_offset + rows) {
        state.viewport_offset = state.cursor.y - rows + 1;
    }
    state.viewport_offset = @min(state.viewport_offset, scroll.maxOffset(rows));
}
