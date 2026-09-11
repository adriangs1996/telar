const CommandContext = @This();
const model = @import("model.zig");
author: model.schema.HistoryAuthor = .human,
origin: model.schema.HistoryOrigin = .pane,
session_id: model.SessionId,
pane_id: model.schema.PaneId,
location: model.schema.TabLocation,
sequence: u64,
workspace_path: []const u8,
cols: u16,
rows: u16,
provider: []const u8 = "",
tool_call_id: []const u8 = "",
