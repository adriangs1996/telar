//! Package-level test root for the runtime proxy capability.

const std = @import("std");
const proxy = @import("proxy/proxy_namespace.zig");

test {
    std.testing.refAllDecls(proxy);
}
