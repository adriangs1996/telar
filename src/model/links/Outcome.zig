const LinkTarget = @import("LinkTarget.zig");

consumed: bool = false,
open: ?LinkTarget = null,
copy: ?LinkTarget = null,
