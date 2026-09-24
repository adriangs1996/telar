const Head = @import("Head.zig");
const Rewrite = @import("../Rewrite.zig");
const Input = @This();

original: []const u8,
original_head: Head,
is_response: bool,
response_to_head: bool,
rewrites: []const Rewrite,
output: []u8,
