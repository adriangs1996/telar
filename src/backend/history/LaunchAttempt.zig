const core = @import("telar-core");
const model = @import("model.zig");
const std = @import("std");
const LaunchAttempt = @This();

pane_id: core.PaneId,
pane_generation: u64,
location: core.TabLocation,
started_at_ms: i64,
failed_at_ms: i64,
phase: model.LaunchPhase,
workspace_path: []u8,
shell: []u8,
cause: []u8,

pub fn deinit(self: *LaunchAttempt, gpa: std.mem.Allocator) void {
    gpa.free(self.workspace_path);
    gpa.free(self.shell);
    gpa.free(self.cause);
    gpa.destroy(self);
}
