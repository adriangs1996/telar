const LaunchAttempt = @This();
const source_namespace = @import("model.zig");
const std = @import("std");
pane_id: source_namespace.schema.PaneId,
pane_generation: u64,
location: source_namespace.schema.TabLocation,
started_at_ms: i64,
failed_at_ms: i64,
phase: source_namespace.LaunchPhase,
workspace_path: []u8,
shell: []u8,
cause: []u8,

pub fn deinit(value: *LaunchAttempt, gpa: std.mem.Allocator) void {
    gpa.free(value.workspace_path);
    gpa.free(value.shell);
    gpa.free(value.cause);
    gpa.destroy(value);
}
