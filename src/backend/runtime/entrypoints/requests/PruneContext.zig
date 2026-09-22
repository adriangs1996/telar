const core = @import("telar-core");
const std = @import("std");
const QueryOriginType = @import("../../../history/QueryOrigin.zig");
const PruneContext = @This();

io: std.Io,
origin: QueryOriginType,
request: core.PruneHistory,
