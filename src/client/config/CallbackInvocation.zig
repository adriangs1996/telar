const CallbackRefType = @import("../input/CallbackRef.zig");
const CallbackContextType = @import("CallbackContext.zig");
const CallbackInvocation = @This();

reference: CallbackRefType,
context: CallbackContextType,
