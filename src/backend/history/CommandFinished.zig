const model = @import("model.zig");
const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const HistoryAuthorType = @import("telar-core").HistoryAuthor;
const HistoryOriginType = @import("telar-core").HistoryOrigin;
const std = @import("std");
const CommandFinished = @This();

session_id: model.SessionId,
pane_id: PaneIdType,
location: TabLocationType,
sequence: u64,
started_at_ms: i64,
duration_ns: i64,
exit_code: ?i32,
status: model.CommandStatus,
author: HistoryAuthorType,
origin: HistoryOriginType = .pane,
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

pub fn deinit(value: *CommandFinished, gpa: std.mem.Allocator) void {
    const allocation_len = @sizeOf(CommandFinished) + value.command.len +
        value.cwd.len + value.workspace_path.len + value.provider.len +
        value.tool_call_id.len + value.output.len;
    const allocation: [*]align(@alignOf(CommandFinished)) u8 = @ptrCast(value);
    gpa.free(allocation[0..allocation_len]);
}
