const State = @This();

scroll: u16 = 0,
total_rows: u16 = 0,

pub fn scrollBy(state: *State, rows: i16, viewport_height: u16) bool {
    const max_scroll = state.total_rows -| viewport_height;
    const before = state.scroll;
    if (rows < 0) {
        state.scroll -|= @intCast(-rows);
    } else {
        state.scroll = @min(max_scroll, state.scroll +| @as(u16, @intCast(rows)));
    }
    return before != state.scroll;
}
