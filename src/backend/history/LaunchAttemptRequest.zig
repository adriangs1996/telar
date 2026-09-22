const core = @import("telar-core");
const model = @import("model.zig");
const LaunchAttemptRequest = @This();

pane_id: core.PaneId,
pane_generation: u64,
location: core.TabLocation,
workspace_path: []const u8,
shell: []const u8,
started_at_ms: i64,
phase: model.LaunchPhase,
cause: []const u8,
