const DecisionInput = @This();
const Callback = @import("Callback.zig");
index: c_int,
callback: *const Callback,
