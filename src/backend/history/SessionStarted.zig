const model = @import("model.zig");
const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const std = @import("std");
const SessionStarted = @This();

id: model.SessionId,
pane_id: PaneIdType,
location: TabLocationType,
started_at_ms: i64,
workspace_path: []u8,
shell: []u8,

pub fn deinit(value: *SessionStarted, gpa: std.mem.Allocator) void {
    gpa.free(value.workspace_path);
    gpa.free(value.shell);
    gpa.destroy(value);
}
