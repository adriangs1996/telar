const types = @import("types.zig");
const source_namespace = @import("connection.zig");
/// Supplies semantic operations for one reusable HTTP/1.1 connection.
///
/// ```zig
/// const port: Port(Context) = .{ ... };
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        read_request: *const fn (*Context) ?types.RequestHead,
        exchange: *const fn (*Context, types.RequestHead) source_namespace.ExchangeOutcome,
        publish_request: *const fn (*Context, types.RequestHead) void,
        publish_response: *const fn (*Context, types.ResponseHead) void,
        publish_failure: *const fn (*Context) void,
        upgrade: *const fn (*Context) void,
    };
}
