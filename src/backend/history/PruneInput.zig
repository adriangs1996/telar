const core = @import("telar-core");
const QueryOrigin = @import("QueryOrigin.zig");
const Input = @This();

request_id: core.RequestId,
origin: QueryOrigin,
scope: core.HistoryScope = .global,
scope_value: []const u8 = "",
pane_id: core.PaneId = .invalid,
before_ms: i64 = 0,
failed_only: bool = false,
match: []const u8 = "",
