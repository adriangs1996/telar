const GenericAttempt = @import("GenericAttempt.zig").Type;
const GenericRoute = @import("GenericRoute.zig").Type;

/// Creates the policy command for one authenticated CONNECT tunnel.
///
/// ```zig
/// const EstablishTunnel = Command(Context, port);
/// const route = EstablishTunnel.execute(&context, attempt);
/// ```
pub fn Type(comptime Context: type, comptime port: anytype) type {
    const PortType = @TypeOf(port);
    const Stream = PortType.StreamType;
    const Session = PortType.SessionType;

    return struct {
        /// Passes every host through unless policy explicitly authorizes its
        /// interception. A successful interception transfers session ownership
        /// through an explicit HTTP/1.1 or HTTP/2 route. Every TLS failure
        /// records its exact stage, publishes one failed request, and returns
        /// `null`.
        ///
        /// ```zig
        /// const route = EstablishTunnel.execute(&context, attempt);
        /// ```
        pub fn execute(context: *Context, attempt: GenericAttempt(Stream)) ?GenericRoute(Session) {
            if (!port.should_intercept(context, attempt.host)) {
                port.record_passthrough(context);
                return .passthrough;
            }

            const established = port.intercept(context, attempt) catch |failure| {
                port.record_failure(context, failure);
                port.publish_failure(context);
                return null;
            };

            return switch (established.protocol) {
                .http11 => .{ .http11 = established.session },
                .h2 => .{ .h2 = established.session },
            };
        }
    };
}
