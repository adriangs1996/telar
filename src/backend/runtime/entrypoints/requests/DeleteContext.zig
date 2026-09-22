const core = @import("telar-core");
const std = @import("std");
const QueryOriginType = @import("../../../history/QueryOrigin.zig");
const DeleteContext = @This();

io: std.Io,
origin: QueryOriginType,
request: core.DeleteHistory,
