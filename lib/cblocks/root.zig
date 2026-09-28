//! `malloc`-style blocks from a Zig allocator, for C libraries that take
//! allocation hooks but free a block by its pointer alone.

const blocks = @import("blocks.zig");

pub const alloc = blocks.alloc;
pub const zeroed = blocks.zeroed;
pub const realloc = blocks.realloc;
pub const free = blocks.free;
pub const len = blocks.len;
pub const roundUp = blocks.roundUp;

test {
    _ = @import("blocks.zig");
}
