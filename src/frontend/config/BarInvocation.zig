const BarInvocation = @This();
const bars = @import("../bars/root.zig");
const BarCallbackContext = @import("BarCallbackContext.zig");
reference: bars.CallbackRef,
context: BarCallbackContext,
