const SessionStarted = @This();
const source_namespace = @import("model.zig");
const std = @import("std");
id: source_namespace.SessionId,
pane_id: source_namespace.schema.PaneId,
location: source_namespace.schema.TabLocation,
started_at_ms: i64,
workspace_path: []u8,
shell: []u8,

pub fn deinit(value: *SessionStarted, gpa: std.mem.Allocator) void {
    gpa.free(value.workspace_path);
    gpa.free(value.shell);
    gpa.destroy(value);
}
