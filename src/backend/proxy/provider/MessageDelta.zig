const Delta = @import("Delta.zig");
const MessageDelta = @This();

type: ?[]const u8 = null,
delta: ?Delta = null,
