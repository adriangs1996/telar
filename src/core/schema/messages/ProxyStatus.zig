const types = @import("../types.zig");
const ProxyStatus = @This();

active: bool,
scope: types.ProxyScope,
system_trusted: bool,

pub fn validateWire(message: ProxyStatus) !void {
    _ = message;
}
