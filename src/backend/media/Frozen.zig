const ShmNameType = @import("telar-core").ShmName;
const Frozen = @This();

pixels: []u8 = &.{},
name: ?ShmNameType = null,
reserved_len: usize,
