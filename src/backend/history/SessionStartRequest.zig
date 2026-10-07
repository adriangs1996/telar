const core = @import("telar-core");
const model = @import("model.zig");

session_id: model.SessionId,
pane_id: core.PaneId,
location: core.TabLocation,
workspace_path: []const u8,
shell: []const u8,
started_at_ms: i64,
