const CallbackRefType = @import("../bars/CallbackRef.zig");
const BarCallbackContext = @import("BarCallbackContext.zig");
const BarInvocation = @This();

reference: CallbackRefType,
context: BarCallbackContext,
