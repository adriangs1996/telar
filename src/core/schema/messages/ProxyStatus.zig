const types = @import("../types.zig");
const ProxyStatus = @This();

active: bool,
scope: types.ProxyScope,
system_trusted: bool,
/// The loopback port the proxy listens on; null while it is disabled.
port: ?u16 = null,
/// The port the proxy tried first, the one this runtime bound last time;
/// null when it remembered none. A different `port` means another process
/// held it, and children that inherited it no longer reach this proxy.
preferred_port: ?u16 = null,

pub fn validateWire(self: ProxyStatus) !void {
    if (self.port == null and self.preferred_port != null) {
        return error.InvalidProxyStatus;
    }
}
