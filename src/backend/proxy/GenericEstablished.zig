const SessionType = @import("Session.zig");

pub fn Type(comptime Session: type) type {
    return struct {
        session: Session,
        protocol: SessionType.Protocol,
    };
}
