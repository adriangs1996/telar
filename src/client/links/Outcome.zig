const Outcome = @This();
const target_mod = @import("root.zig").target;
consumed: bool = false,
open: ?target_mod.Target = null,
