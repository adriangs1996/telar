//! A stack painted into bounds, with the context its buttons register in.
const data = @import("model");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const Context = @import("Context.zig");
const BlockScope = @import("BlockScope.zig");
const BlockStack = @This();

context: *const Context,
bounds: Rect,
scope: BlockScope,
facts: *const data.BarFacts,
