const localca = @import("localca");
const SessionType = localca.Session;

pub fn Type(comptime Session: type) type {
    return struct {
        session: Session,
        protocol: SessionType.Protocol,
    };
}
