const model = @import("model.zig");
const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const SessionStartRequest = @This();

session_id: model.SessionId,
pane_id: PaneIdType,
location: TabLocationType,
workspace_path: []const u8,
shell: []const u8,
started_at_ms: i64,
