const ProxyStatus = @This();
const types = @import("../types.zig");
active: bool,
scope: types.ProxyScope,
system_trusted: bool,

pub fn validateWire(message: ProxyStatus) !void {
    _ = message;
}
