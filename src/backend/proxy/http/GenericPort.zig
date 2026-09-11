const RequestHeadType = @import("RequestHead.zig");
const connection = @import("connection.zig");
const ResponseHeadType = @import("ResponseHead.zig");

/// Supplies semantic operations for one reusable HTTP/1.1 connection.
///
/// ```zig
/// const port: Port(Context) = .{ ... };
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        read_request: *const fn (*Context) ?RequestHeadType,
        exchange: *const fn (*Context, RequestHeadType) connection.ExchangeOutcome,
        publish_request: *const fn (*Context, RequestHeadType) void,
        publish_response: *const fn (*Context, ResponseHeadType) void,
        publish_failure: *const fn (*Context) void,
        upgrade: *const fn (*Context) void,
    };
}
