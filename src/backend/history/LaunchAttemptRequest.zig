const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const model = @import("model.zig");
const LaunchAttemptRequest = @This();

pane_id: PaneIdType,
pane_generation: u64,
location: TabLocationType,
workspace_path: []const u8,
shell: []const u8,
started_at_ms: i64,
phase: model.LaunchPhase,
cause: []const u8,
