//! One path of an index, relative to its root; a directory ends in `/`.

const core = @import("telar-core");
const IndexedPath = @This();

offset: u32,
len: u16,
kind: core.PathKind,
