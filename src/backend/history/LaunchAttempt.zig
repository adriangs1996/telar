const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const model = @import("model.zig");
const std = @import("std");
const LaunchAttempt = @This();

pane_id: PaneIdType,
pane_generation: u64,
location: TabLocationType,
started_at_ms: i64,
failed_at_ms: i64,
phase: model.LaunchPhase,
workspace_path: []u8,
shell: []u8,
cause: []u8,

pub fn deinit(value: *LaunchAttempt, gpa: std.mem.Allocator) void {
    gpa.free(value.workspace_path);
    gpa.free(value.shell);
    gpa.free(value.cause);
    gpa.destroy(value);
}
