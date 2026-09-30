const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const Point = @import("Point.zig");
const PointerSelection = @import("PointerSelection.zig");
const copy_mode = @import("copy_mode.zig");
const View = @import("CopyModeView.zig");
const Screen = @import("Screen.zig");
const PointerMotion = @import("PointerMotion.zig");
const std = @import("std");
const Viewport = @import("Viewport.zig");
const State = @This();

pane_id: core.PaneId,
cursor: Point,
pointer: ?PointerSelection = null,
anchor: ?Point = null,
linewise: bool = false,
entry_offset: u32,
viewport_offset: u32,
search_direction: copy_mode.Direction = .forward,
matches: [core.max_search_matches]core.SearchMatch = @splat(.{
    .x = 0,
    .y = 0,
    .len = 0,
}),
match_count: u16 = 0,
match_index: u16 = 0,

pub fn init(pane_id: core.PaneId, cursor: Point, viewport_offset: u32) State {
    return .{
        .pane_id = pane_id,
        .cursor = cursor,
        .entry_offset = viewport_offset,
        .viewport_offset = viewport_offset,
    };
}

pub fn view(self: State) View {
    return .{
        .cursor = self.cursor,
        .pointer = self.pointer != null,
        .anchor = self.anchor,
        .linewise = self.linewise,
    };
}

/// Captures a word or line boundary once; subsequent drags retain it.
/// Example: `state.beginPointer(.word, screen);`.
pub fn beginPointer(self: *State, granularity: cellgrid.selection.Granularity, screen: Screen) void {
    const span = copy_mode.pointerSpan(
        self.cursor,
        granularity,
        screen,
    );
    self.pointer = .{
        .start = span[0],
        .end = span[1],
        .granularity = granularity,
        .cols = screen.buffer.w,
        .rows = screen.buffer.h,
    };
    self.anchor = if (granularity == .character) null else span[0];
    self.cursor = span[1];
    self.linewise = granularity == .line;
}

/// Extends only within the supplied pane cells, in absolute history rows.
/// Example: `state.movePointer(motion, screen);`.
pub fn movePointer(self: *State, motion: PointerMotion, screen: Screen) void {
    const pointer = if (self.pointer) |*value| value else return;
    if (screen.buffer.w == 0 or screen.buffer.h == 0) {
        return;
    }

    const point: Point = .{
        .x = @min(motion.position.x, screen.buffer.w - 1),
        .y = screen.scroll.offset + @min(motion.position.y, screen.buffer.h - 1),
    };
    const span = copy_mode.pointerSpan(
        point,
        pointer.granularity,
        screen,
    );
    const backwards = copy_mode.less(point, pointer.start);
    self.anchor = if (backwards) pointer.end else pointer.start;
    self.cursor = if (backwards) span[0] else span[1];
    if (pointer.granularity == .character and std.meta.eql(span[0], pointer.start) and std.meta.eql(span[1], pointer.end)) {
        self.anchor = null;
    }
}

pub fn toggleSelection(self: *State, linewise: bool) void {
    if (self.anchor != null and self.linewise == linewise) {
        self.anchor = null;
        self.linewise = false;
        return;
    }
    self.anchor = self.cursor;
    self.linewise = linewise;
}

pub fn clearSelection(self: *State) bool {
    if (self.anchor == null) {
        return false;
    }
    self.anchor = null;
    self.linewise = false;
    return true;
}

pub fn horizontal(self: *State, delta: i32, cols: u16) void {
    if (delta < 0) {
        self.cursor.x -|= @intCast(-delta);
    } else {
        self.cursor.x = @min(cols -| 1, self.cursor.x +| @as(u16, @intCast(delta)));
    }
}

pub fn vertical(self: *State, delta: i32, viewport: Viewport) void {
    const last = viewport.scroll.total_rows -| 1;
    if (delta < 0) {
        self.cursor.y -|= @intCast(-delta);
    } else {
        self.cursor.y = @min(last, self.cursor.y +| @as(u32, @intCast(delta)));
    }
    self.reveal(viewport.rows, viewport.scroll);
}

pub fn top(self: *State) void {
    self.cursor.y = 0;
    self.viewport_offset = 0;
}

pub fn bottom(self: *State, scroll: core.Scroll, rows: u16) void {
    self.cursor.y = scroll.total_rows -| 1;
    self.viewport_offset = scroll.maxOffset(rows);
}

pub fn lineStart(self: *State) void {
    self.cursor.x = 0;
}

pub fn lineEnd(self: *State, cols: u16) void {
    self.cursor.x = cols -| 1;
}

/// Stores search results and selects the first match at or after the
/// cursor (forward) or before it (backward). The current match becomes
/// the selection so it is visibly highlighted.
///
/// ```zig
/// state.applyMatches(results, viewport);
/// ```
pub fn applyMatches(self: *State, results: []const core.SearchMatch, viewport: Viewport) void {
    self.match_count = @intCast(@min(results.len, self.matches.len));
    @memcpy(self.matches[0..self.match_count], results[0..self.match_count]);
    if (self.match_count == 0) {
        return;
    }

    var selected: ?u16 = null;
    switch (self.search_direction) {
        .forward => {
            for (self.matchSlice(), 0..) |match, index| {
                if (copy_mode.less(
                    self.cursor,
                    .{
                        .x = match.x,
                        .y = match.y,
                    },
                )) {
                    selected = @intCast(index);
                    break;
                }
            }
        },
        .backward => {
            var index: usize = self.match_count;
            while (index > 0) {
                index -= 1;
                const match = self.matches[index];
                if (copy_mode.less(
                    .{
                        .x = match.x,
                        .y = match.y,
                    },
                    self.cursor,
                )) {
                    selected = @intCast(index);
                    break;
                }
            }
        },
    }

    self.gotoMatch(selected orelse switch (self.search_direction) {
        .forward => 0,
        .backward => self.match_count - 1,
    }, viewport);
}

/// Moves to the next or previous stored match, wrapping around.
///
/// ```zig
/// state.cycleMatch(1, viewport);
/// ```
pub fn cycleMatch(self: *State, delta: i2, viewport: Viewport) void {
    if (self.match_count == 0) {
        return;
    }

    const count: i32 = self.match_count;
    var index: i32 = self.match_index;
    index = @mod(index + delta, count);
    self.gotoMatch(@intCast(index), viewport);
}

pub fn matchSlice(self: *const State) []const core.SearchMatch {
    return self.matches[0..self.match_count];
}

fn gotoMatch(self: *State, index: u16, viewport: Viewport) void {
    const match = self.matches[index];
    self.match_index = index;
    self.anchor = .{
        .x = match.x,
        .y = match.y,
    };
    self.linewise = false;
    self.cursor = .{
        .x = match.x + match.len - 1,
        .y = match.y,
    };
    self.cursor.y = @min(self.cursor.y, viewport.scroll.total_rows -| 1);
    self.reveal(viewport.rows, viewport.scroll);
}

fn reveal(self: *State, rows: u16, scroll: core.Scroll) void {
    if (self.cursor.y < self.viewport_offset) {
        self.viewport_offset = self.cursor.y;
    } else if (self.cursor.y >= self.viewport_offset + rows) {
        self.viewport_offset = self.cursor.y - rows + 1;
    }
    self.viewport_offset = @min(self.viewport_offset, scroll.maxOffset(rows));
}
