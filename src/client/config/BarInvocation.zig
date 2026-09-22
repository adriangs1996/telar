const data = @import("model");
const BarCallbackContext = @import("BarCallbackContext.zig");
const BarInvocation = @This();

reference: data.CallbackRef,
context: BarCallbackContext,
