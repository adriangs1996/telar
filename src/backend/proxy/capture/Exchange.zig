const Half = @import("Half.zig");
const Exchange = @This();

request: ?*Half = null,
response: ?*Half = null,

/// Erases and frees both owned halves that are present.
///
/// ```zig
/// exchange.deinit();
/// ```
pub fn deinit(self: *Exchange) void {
    if (self.request) |request| {
        request.deinit();
    }

    if (self.response) |response| {
        response.deinit();
    }

    self.* = .{};
}
