const core = @import("telar-core");
const model = @import("model.zig");
const std = @import("std");
const SessionStarted = @This();

id: model.SessionId,
pane_id: core.PaneId,
location: core.TabLocation,
started_at_ms: i64,
workspace_path: []u8,
shell: []u8,

pub fn deinit(self: *SessionStarted, gpa: std.mem.Allocator) void {
    gpa.free(self.workspace_path);
    gpa.free(self.shell);
    gpa.destroy(self);
}
