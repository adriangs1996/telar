const core = @import("telar-core");
const Frozen = @This();

pixels: []u8 = &.{},
name: ?core.ShmName = null,
reserved_len: usize,
