const PositionType = @import("telar-client").Position;
const CallbackRefType = @import("telar-client").CallbackRef;
const CallbackRequest = @This();

position: PositionType,
reference: CallbackRefType,
output: ?[]const u8 = null,
