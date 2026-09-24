const uri = @import("uri.zig");
const Prefix = @This();

text: []const u8,
scheme: uri.Scheme,
