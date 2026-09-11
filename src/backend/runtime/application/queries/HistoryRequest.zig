const Request = @This();
const source_namespace = @import("history.zig");
const history_mod = @import("../../../history/root.zig");
request_id: source_namespace.schema.RequestId,
origin: source_namespace.QueryOrigin,
text: []const u8,
scope: history_mod.model.Scope,
scope_value: []const u8,
pane_id: source_namespace.schema.PaneId,
failed_only: bool,
author: source_namespace.schema.HistoryAuthorFilter,
match: source_namespace.schema.HistoryMatch,
distinct: bool,
limit: u16,
offset: u32 = 0,
snapshot_id: u64 = 0,
entry_id: u64 = 0,
