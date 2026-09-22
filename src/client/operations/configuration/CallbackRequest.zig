const model = @import("../../bars/model.zig");
const CallbackRefType = @import("../../bars/CallbackRef.zig");
const CallbackRequest = @This();

position: model.Position,
reference: CallbackRefType,
output: ?[]const u8 = null,
