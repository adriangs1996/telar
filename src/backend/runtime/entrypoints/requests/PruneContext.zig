const std = @import("std");
const QueryOriginType = @import("../../../history/QueryOrigin.zig");
const PruneHistoryType = @import("telar-core").PruneHistory;
const PruneContext = @This();

io: std.Io,
origin: QueryOriginType,
request: PruneHistoryType,
