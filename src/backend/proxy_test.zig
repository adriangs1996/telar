//! Package-level test root for the runtime proxy capability.

const proxy = @import("proxy/root.zig");

test {
    @import("std").testing.refAllDecls(proxy);
}
