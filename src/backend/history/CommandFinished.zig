const core = @import("telar-core");
const model = @import("model.zig");
const std = @import("std");
const CommandFinished = @This();

session_id: model.SessionId,
pane_id: core.PaneId,
location: core.TabLocation,
sequence: u64,
started_at_ms: i64,
duration_ns: i64,
exit_code: ?i32,
status: model.CommandStatus,
author: core.HistoryAuthor,
origin: core.HistoryOrigin = .pane,
cols: u16,
rows: u16,
command: []u8,
cwd: []u8,
workspace_path: []u8,
provider: []u8 = &.{},
tool_call_id: []u8 = &.{},
command_truncated: bool,
output: []u8,
output_truncated: bool,
output_observed: u64,

pub fn deinit(self: *CommandFinished, gpa: std.mem.Allocator) void {
    const allocation_len = @sizeOf(CommandFinished) + self.command.len +
        self.cwd.len + self.workspace_path.len + self.provider.len +
        self.tool_call_id.len + self.output.len;
    const allocation: [*]align(@alignOf(CommandFinished)) u8 = @ptrCast(self);
    gpa.free(allocation[0..allocation_len]);
}
