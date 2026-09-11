const GenericAttempt = @import("GenericAttempt.zig").Type;
const tls = @import("tls.zig");
const GenericEstablished = @import("GenericEstablished.zig").Type;
/// Defines interception policy, TLS establishment, metrics, and failure
/// publication supplied by the proxy service.
///
/// ```zig
/// const port: Port(Context, Stream, Session) = .{ ... };
/// ```
pub fn Type(comptime Context: type, comptime Stream: type, comptime Session: type) type {
    return struct {
        pub const StreamType = Stream;
        pub const SessionType = Session;

        should_intercept: *const fn (*Context, []const u8) bool,
        record_passthrough: *const fn (*Context) void,
        intercept: *const fn (*Context, GenericAttempt(Stream)) tls.Error!GenericEstablished(Session),
        record_failure: *const fn (*Context, tls.Error) void,
        publish_failure: *const fn (*Context) void,
    };
}
