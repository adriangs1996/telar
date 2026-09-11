const Frozen = @This();
const core = @import("telar-core");
pixels: []u8 = &.{},
name: ?core.graphics.ShmName = null,
reserved_len: usize,
