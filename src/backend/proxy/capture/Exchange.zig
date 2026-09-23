const Half = @import("Half.zig");
const Exchange = @This();

request: ?*Half = null,
response: ?*Half = null,

/// Erases and frees both owned halves that are present.
///
/// ```zig
/// exchange.deinit();
/// ```
pub fn deinit(exchange: *Exchange) void {
    if (exchange.request) |request| {
        request.deinit();
    }

    if (exchange.response) |response| {
        response.deinit();
    }

    exchange.* = .{};
}
