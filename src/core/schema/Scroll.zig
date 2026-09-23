/// Position of one client's viewport in the runtime-owned scrollback.
const Scroll = @This();

total_rows: u32,
offset: u32,

pub fn maxOffset(self: Scroll, rows: u16) u32 {
    return self.total_rows -| rows;
}

pub fn atBottom(self: Scroll, rows: u16) bool {
    return self.offset == self.maxOffset(rows);
}
