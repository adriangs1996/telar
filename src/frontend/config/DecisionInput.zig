const Callback = @import("Callback.zig");
const DecisionInput = @This();

index: c_int,
callback: *const Callback,
