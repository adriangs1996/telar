//! A stack measured at a width.
const data = @import("model");
const BlockScope = @import("BlockScope.zig");
const BlockLayout = @This();

scope: BlockScope,
width: f32,
facts: *const data.BarFacts,
