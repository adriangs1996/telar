const TargetType = @import("LinkTarget.zig");
const Outcome = @This();

consumed: bool = false,
open: ?TargetType = null,
