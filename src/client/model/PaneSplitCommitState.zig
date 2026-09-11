const PaneSplitCommitState = @This();
const source_namespace = @import("types.zig");
disposition: source_namespace.PaneSplitDisposition,
change: source_namespace.Change,
layout_revision: u64,
