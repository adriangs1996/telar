const Exchange = @This();
const buffer = @import("buffer_support.zig");
request: ?*buffer.Half = null,
response: ?*buffer.Half = null,

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
