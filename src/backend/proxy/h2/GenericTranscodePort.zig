const tls = @import("../tls.zig");
const source_namespace = @import("relay.zig");
pub fn Type(comptime Session: type, comptime Sink: type) type {
    return struct {
        session: Session,
        sink: Sink,

        pub fn writeAll(port: @This(), to: tls.Session.Side, bytes: []const u8) bool {
            return port.session.writeAll(to, bytes);
        }

        pub fn emit(port: @This(), event: source_namespace.Event) void {
            port.sink.emit(event);
        }
    };
}
