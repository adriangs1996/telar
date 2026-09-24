const Mouse = @This();

x: u16,
y: u16,
raw_x: u32 = 0,
raw_y: u32 = 0,
kind: Kind,
button: u8 = 0,

pub const Kind = enum { press, release, drag, scroll_up, scroll_down, move };
