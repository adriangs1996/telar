const CallbackRef = @import("CallbackRef.zig");
const Dynamic = @This();

callback: CallbackRef,
interval_ns: u64,
