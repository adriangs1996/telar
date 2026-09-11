//! Runtime boundary for owned ProxyTLS capture halves.

const std = @import("std");
const pane_mod = @import("../../../pane/root.zig");
const proxy_mod = @import("../../../proxy/root.zig");
const proxy_resource = @import("../../resources/proxy.zig");

const Io = std.Io;

pub const Resources = @import("ProxyCaptureResources.zig");

pub const RuntimePort = @import("GenericProxyCaptureRuntimePort.zig").Type;

pub const Adapter = @import("GenericProxyCaptureAdapter.zig").Type;

test {
    std.testing.refAllDecls(@This());
}
