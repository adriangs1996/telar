const id = @import("../id.zig");
const types = @import("../types.zig");
const history = @import("history.zig");
const QueryHistory = @This();

request_id: id.RequestId,
query: []const u8 = "",
scope: types.HistoryScope = .global,
scope_value: []const u8 = "",
pane_id: id.PaneId = .invalid,
failed_only: bool = false,
author: types.HistoryAuthorFilter = .all,
match: history.HistoryMatch = .fts,
distinct: bool = false,
limit: u16 = 20,
offset: u32 = 0,
snapshot_id: u64 = 0,
entry_id: u64 = 0,
