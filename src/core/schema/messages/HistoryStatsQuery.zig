const id = @import("../id.zig");
const types = @import("../types.zig");
/// Aggregates command history in one scope since a timestamp (0 = all).
const HistoryStatsQuery = @This();

request_id: id.RequestId,
scope: types.HistoryScope = .global,
scope_value: []const u8 = "",
pane_id: id.PaneId = .invalid,
since_ms: i64 = 0,
