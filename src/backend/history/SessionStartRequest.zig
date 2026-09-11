const SessionStartRequest = @This();
const model = @import("model.zig");
session_id: model.SessionId,
pane_id: model.schema.PaneId,
location: model.schema.TabLocation,
workspace_path: []const u8,
shell: []const u8,
started_at_ms: i64,
