const types = @import("../types.zig");
const ProxyStatus = @This();

active: bool,
scope: types.ProxyScope,
system_trusted: bool,

pub fn validateWire(self: ProxyStatus) !void {
    _ = self;
}
