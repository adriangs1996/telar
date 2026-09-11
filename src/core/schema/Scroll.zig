/// Position of one client's viewport in the runtime-owned scrollback.
const Scroll = @This();

total_rows: u32,
offset: u32,

pub fn maxOffset(scroll: Scroll, rows: u16) u32 {
    return scroll.total_rows -| rows;
}

pub fn atBottom(scroll: Scroll, rows: u16) bool {
    return scroll.offset == scroll.maxOffset(rows);
}
