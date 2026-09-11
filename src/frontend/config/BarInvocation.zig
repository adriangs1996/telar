const CallbackRefType = @import("telar-client").CallbackRef;
const BarCallbackContext = @import("BarCallbackContext.zig");
const BarInvocation = @This();

reference: CallbackRefType,
context: BarCallbackContext,
