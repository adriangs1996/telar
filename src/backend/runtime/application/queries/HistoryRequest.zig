const core = @import("telar-core");
const QueryOriginType = @import("../../../history/QueryOrigin.zig");
const Request = @This();

request_id: core.RequestId,
origin: QueryOriginType,
text: []const u8,
scope: core.HistoryScope,
scope_value: []const u8,
pane_id: core.PaneId,
failed_only: bool,
author: core.HistoryAuthorFilter,
match: core.HistoryMatch,
distinct: bool,
limit: u16,
offset: u32 = 0,
snapshot_id: u64 = 0,
entry_id: u64 = 0,
