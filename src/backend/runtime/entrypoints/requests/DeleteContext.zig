const std = @import("std");
const QueryOriginType = @import("../../../history/QueryOrigin.zig");
const DeleteHistoryType = @import("telar-core").DeleteHistory;
const DeleteContext = @This();

io: std.Io,
origin: QueryOriginType,
request: DeleteHistoryType,
