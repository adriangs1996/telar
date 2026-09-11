const Asset = @This();

pixels: []u8 = &.{},
width: u32 = 0,
height: u32 = 0,
dirty: bool = false,
emitted: bool = false,
transfer_offset: usize = 0,
