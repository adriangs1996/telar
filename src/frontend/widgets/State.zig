const State = @This();

scroll: u16 = 0,
total_rows: u16 = 0,

pub fn scrollBy(self: *State, rows: i16, viewport_height: u16) bool {
    const max_scroll = self.total_rows -| viewport_height;
    const before = self.scroll;
    if (rows < 0) {
        self.scroll -|= @intCast(-rows);
    } else {
        self.scroll = @min(max_scroll, self.scroll +| @as(u16, @intCast(rows)));
    }
    return before != self.scroll;
}
