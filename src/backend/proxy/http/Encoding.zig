const HeadersType = @import("../Headers.zig");
const Encoding = @This();

output: []u8,
start_line: []const u8,
is_response: bool,
headers: *const HeadersType,
