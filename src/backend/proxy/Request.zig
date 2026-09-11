const std = @import("std");
const TransformContext = @import("TransformContext.zig");
const Headers = @import("Headers.zig");
const Request = @This();

io: std.Io,
context: TransformContext,
headers: *Headers,
