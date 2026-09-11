const LaunchAttemptRequest = @This();
const model = @import("model.zig");
pane_id: model.schema.PaneId,
pane_generation: u64,
location: model.schema.TabLocation,
workspace_path: []const u8,
shell: []const u8,
started_at_ms: i64,
phase: model.LaunchPhase,
cause: []const u8,
