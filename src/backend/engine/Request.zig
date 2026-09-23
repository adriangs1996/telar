const Response = @import("Response.zig");
const Request = @This();

prompt: []const u8,
response: *Response,
