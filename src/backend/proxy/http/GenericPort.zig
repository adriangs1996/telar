const RequestHead = @import("RequestHead.zig");
const connection = @import("connection.zig");
const ResponseHead = @import("ResponseHead.zig");

/// Supplies semantic operations for one reusable HTTP/1.1 connection.
///
/// ```zig
/// const port: Port(Context) = .{ ... };
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        read_request: *const fn (*Context) ?RequestHead,
        exchange: *const fn (*Context, RequestHead) connection.ExchangeOutcome,
        publish_request: *const fn (*Context, RequestHead) void,
        publish_response: *const fn (*Context, ResponseHead) void,
        publish_failure: *const fn (*Context) void,
        upgrade: *const fn (*Context) void,
    };
}
