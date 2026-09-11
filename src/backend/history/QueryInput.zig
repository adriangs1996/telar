const RequestIdType = @import("telar-core").RequestId;
const QueryOrigin = @import("QueryOrigin.zig");
const HistoryScope = @import("telar-core").HistoryScope;
const PaneIdType = @import("telar-core").PaneId;
const HistoryAuthorFilterType = @import("telar-core").HistoryAuthorFilter;
const HistoryMatchType = @import("telar-core").HistoryMatch;
const Input = @This();

request_id: RequestIdType,
origin: QueryOrigin,
text: []const u8 = "",
scope: HistoryScope = .global,
scope_value: []const u8 = "",
pane_id: PaneIdType = .invalid,
failed_only: bool = false,
author: HistoryAuthorFilterType = .all,
match: HistoryMatchType = .fts,
distinct: bool = false,
limit: u16 = 20,
offset: u32 = 0,
snapshot_id: u64 = 0,
entry_id: u64 = 0,
