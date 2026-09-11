const Encoding = @This();
const middleware = @import("../middleware.zig");
output: []u8,
start_line: []const u8,
is_response: bool,
headers: *const middleware.Headers,
