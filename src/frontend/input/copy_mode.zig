//! Client-owned copy-mode cursor and selection.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;

pub const Point = struct {
    x: u16,
    /// Absolute row from the beginning of the retained screen history.
    y: u32,
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

    pub fn init(
        pane_id: schema.PaneId,
        cursor: Point,
        viewport_offset: u32,
    ) State {
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
        if (state.anchor == null) return false;
        state.anchor = null;
        state.linewise = false;
        return true;
    }

    pub fn horizontal(state: *State, delta: i32, cols: u16) void {
        if (delta < 0)
            state.cursor.x -|= @intCast(-delta)
        else
            state.cursor.x = @min(cols -| 1, state.cursor.x +| @as(u16, @intCast(delta)));
    }

    pub fn vertical(state: *State, delta: i32, scroll: schema.frame.Scroll, rows: u16) void {
        const last = scroll.total_rows -| 1;
        if (delta < 0)
            state.cursor.y -|= @intCast(-delta)
        else
            state.cursor.y = @min(last, state.cursor.y +| @as(u32, @intCast(delta)));
        state.reveal(rows, scroll);
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

test "vertical movement scrolls the viewport only at its edges" {
    const scroll: schema.frame.Scroll = .{ .total_rows = 100, .offset = 90 };
    var state = State.init(@enumFromInt(1), .{ .x = 2, .y = 99 }, 90);
    state.vertical(-1, scroll, 10);
    try std.testing.expectEqual(@as(u32, 90), state.viewport_offset);
    state.vertical(-20, scroll, 10);
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
