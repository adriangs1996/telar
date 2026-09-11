const PaneIdType = @import("telar-core").PaneId;
const model = @import("model.zig");
const HistoryAuthorType = @import("telar-core").HistoryAuthor;
const HistoryOriginType = @import("telar-core").HistoryOrigin;
const std = @import("std");
const Entry = @This();

id: u64,
pane_id: PaneIdType,
started_at_ms: i64,
duration_ns: i64,
exit_code: ?i32,
status: model.CommandStatus,
author: HistoryAuthorType,
origin: HistoryOriginType = .pane,
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
