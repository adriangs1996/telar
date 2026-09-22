const model_data = @import("../model.zig");
const PaneSplitCommitState = @This();

disposition: model_data.PaneSplitDisposition,
change: model_data.Change,
layout_revision: u64,
