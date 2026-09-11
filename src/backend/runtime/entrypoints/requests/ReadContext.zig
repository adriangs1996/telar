const std = @import("std");
const QueryOriginType = @import("../../../history/QueryOrigin.zig");
const ReadHistoryOutputType = @import("telar-core").ReadHistoryOutput;
const ReadContext = @This();

io: std.Io,
origin: QueryOriginType,
request: ReadHistoryOutputType,
