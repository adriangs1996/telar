const Data = @import("Data.zig");
const Envelope = @This();

type: []const u8 = "",
command: []const u8 = "",
success: ?bool = null,
data: ?Data = null,
