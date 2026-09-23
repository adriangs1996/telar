const core = @import("telar-core");
const model = @import("model.zig");
const std = @import("std");
const Entry = @This();

id: u64,
pane_id: core.PaneId,
started_at_ms: i64,
duration_ns: i64,
exit_code: ?i32,
status: model.CommandStatus,
author: core.HistoryAuthor,
origin: core.HistoryOrigin = .pane,
command: []u8,
cwd: []u8,
workspace_path: []u8,
provider: []u8 = &.{},
command_truncated: bool = false,

pub fn deinit(self: *Entry, gpa: std.mem.Allocator) void {
    gpa.free(self.command);
    gpa.free(self.cwd);
    gpa.free(self.workspace_path);
    gpa.free(self.provider);
}
