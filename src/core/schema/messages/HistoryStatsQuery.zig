/// Aggregates command history in one scope since a timestamp (0 = all).
const HistoryStatsQuery = @This();
const source_namespace = @import("history.zig");
request_id: source_namespace.RequestId,
scope: source_namespace.HistoryScope = .global,
scope_value: []const u8 = "",
pane_id: source_namespace.PaneId = .invalid,
since_ms: i64 = 0,
