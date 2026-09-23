const LinkTarget = @import("LinkTarget.zig");
const Outcome = @This();

consumed: bool = false,
open: ?LinkTarget = null,
copy: ?LinkTarget = null,
