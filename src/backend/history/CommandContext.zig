const core = @import("telar-core");
const model = @import("model.zig");
const CommandContext = @This();

author: core.HistoryAuthor = .human,
origin: core.HistoryOrigin = .pane,
session_id: model.SessionId,
pane_id: core.PaneId,
location: core.TabLocation,
sequence: u64,
workspace_path: []const u8,
cols: u16,
rows: u16,
provider: []const u8 = "",
tool_call_id: []const u8 = "",
