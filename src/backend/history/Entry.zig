const Entry = @This();
const source_namespace = @import("model.zig");
const std = @import("std");
id: u64,
pane_id: source_namespace.schema.PaneId,
started_at_ms: i64,
duration_ns: i64,
exit_code: ?i32,
status: source_namespace.CommandStatus,
author: source_namespace.schema.HistoryAuthor,
origin: source_namespace.schema.HistoryOrigin = .pane,
command: []u8,
cwd: []u8,
workspace_path: []u8,
provider: []u8 = &.{},
command_truncated: bool = false,

pub fn deinit(entry: *Entry, gpa: std.mem.Allocator) void {
    gpa.free(entry.command);
    gpa.free(entry.cwd);
    gpa.free(entry.workspace_path);
    gpa.free(entry.provider);
}
