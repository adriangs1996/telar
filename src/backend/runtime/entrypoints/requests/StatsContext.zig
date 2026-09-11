const std = @import("std");
const QueryOriginType = @import("../../../history/QueryOrigin.zig");
const HistoryStatsQueryType = @import("telar-core").HistoryStatsQuery;
const StatsContext = @This();

io: std.Io,
origin: QueryOriginType,
request: HistoryStatsQueryType,
