const SessionType = @import("../Session.zig");
const relay = @import("relay.zig");

pub fn Type(comptime Session: type, comptime Sink: type) type {
    return struct {
        session: Session,
        sink: Sink,

        pub fn writeAll(port: @This(), to: SessionType.Side, bytes: []const u8) bool {
            return port.session.writeAll(to, bytes);
        }

        pub fn emit(port: @This(), event: relay.Event) void {
            port.sink.emit(event);
        }
    };
}
