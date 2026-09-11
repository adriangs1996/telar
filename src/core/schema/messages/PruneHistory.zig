const id = @import("../id.zig");
const types = @import("../types.zig");
/// Deletes every history entry matching the bounded filters. `before_ms = 0`
/// means no time bound and an empty `match` means no text filter.
const PruneHistory = @This();

request_id: id.RequestId,
scope: types.HistoryScope = .global,
scope_value: []const u8 = "",
pane_id: id.PaneId = .invalid,
before_ms: i64 = 0,
failed_only: bool = false,
match: []const u8 = "",
