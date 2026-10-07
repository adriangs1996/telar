const core = @import("telar-core");

pixels: []u8 = &.{},
name: ?core.ShmName = null,
reserved_len: usize,
