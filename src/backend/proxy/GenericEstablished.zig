const tls = @import("tls.zig");
pub fn Type(comptime Session: type) type {
    return struct {
        session: Session,
        protocol: tls.Session.Protocol,
    };
}
