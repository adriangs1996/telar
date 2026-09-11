const RequestIdType = @import("telar-core").RequestId;
const QueryOrigin = @import("QueryOrigin.zig");
const HistoryScope = @import("telar-core").HistoryScope;
const PaneIdType = @import("telar-core").PaneId;
const Input = @This();

request_id: RequestIdType,
origin: QueryOrigin,
scope: HistoryScope = .global,
scope_value: []const u8 = "",
pane_id: PaneIdType = .invalid,
since_ms: i64 = 0,
