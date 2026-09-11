const Request = @import("Request.zig");
const Frozen = @import("Frozen.zig");
const Entry = @This();

request: Request,
result: ?anyerror!Frozen = null,
