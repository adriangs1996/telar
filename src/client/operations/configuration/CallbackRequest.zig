const PositionType = @import("../../bars/model.zig").Position;
const CallbackRefType = @import("../../bars/CallbackRef.zig");
const CallbackRequest = @This();

position: PositionType,
reference: CallbackRefType,
output: ?[]const u8 = null,
