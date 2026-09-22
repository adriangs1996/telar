const core = @import("telar-core");
const QueryOrigin = @import("QueryOrigin.zig");
const Input = @This();

request_id: core.RequestId,
origin: QueryOrigin,
text: []const u8 = "",
scope: core.HistoryScope = .global,
scope_value: []const u8 = "",
pane_id: core.PaneId = .invalid,
failed_only: bool = false,
author: core.HistoryAuthorFilter = .all,
match: core.HistoryMatch = .fts,
distinct: bool = false,
limit: u16 = 20,
offset: u32 = 0,
snapshot_id: u64 = 0,
entry_id: u64 = 0,
