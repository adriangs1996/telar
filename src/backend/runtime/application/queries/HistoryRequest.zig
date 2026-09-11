const RequestIdType = @import("telar-core").RequestId;
const QueryOriginType = @import("../../../history/QueryOrigin.zig");
const HistoryScope = @import("telar-core").HistoryScope;
const PaneIdType = @import("telar-core").PaneId;
const HistoryAuthorFilterType = @import("telar-core").HistoryAuthorFilter;
const HistoryMatchType = @import("telar-core").HistoryMatch;
const Request = @This();

request_id: RequestIdType,
origin: QueryOriginType,
text: []const u8,
scope: HistoryScope,
scope_value: []const u8,
pane_id: PaneIdType,
failed_only: bool,
author: HistoryAuthorFilterType,
match: HistoryMatchType,
distinct: bool,
limit: u16,
offset: u32 = 0,
snapshot_id: u64 = 0,
entry_id: u64 = 0,
