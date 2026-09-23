const data = @import("model");
const CallbackRequest = @This();

position: data.bar_values.Position,
reference: data.CallbackRef,
output: ?[]const u8 = null,
