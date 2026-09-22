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

pub fn deinit(value: *SessionStarted, gpa: std.mem.Allocator) void {
    gpa.free(value.workspace_path);
    gpa.free(value.shell);
    gpa.destroy(value);
}
