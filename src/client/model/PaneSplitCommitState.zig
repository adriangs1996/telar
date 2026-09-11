const types = @import("types.zig");
const PaneSplitCommitState = @This();

disposition: types.PaneSplitDisposition,
change: types.Change,
layout_revision: u64,
