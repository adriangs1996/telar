const Entry = @This();
const Request = @import("Request.zig");
const Frozen = @import("Frozen.zig");
request: Request,
result: ?anyerror!Frozen = null,
