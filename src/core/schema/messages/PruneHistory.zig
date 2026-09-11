/// Deletes every history entry matching the bounded filters. `before_ms = 0`
/// means no time bound and an empty `match` means no text filter.
const PruneHistory = @This();
const source_namespace = @import("history.zig");
request_id: source_namespace.RequestId,
scope: source_namespace.HistoryScope = .global,
scope_value: []const u8 = "",
pane_id: source_namespace.PaneId = .invalid,
before_ms: i64 = 0,
failed_only: bool = false,
match: []const u8 = "",
