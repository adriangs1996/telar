const CallbackRequest = @This();
const bars = @import("../../../bars/root.zig");
position: bars.Position,
reference: bars.CallbackRef,
output: ?[]const u8 = null,
