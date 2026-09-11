const HistoryAuthorType = @import("telar-core").HistoryAuthor;
const HistoryOriginType = @import("telar-core").HistoryOrigin;
const model = @import("model.zig");
const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const CommandContext = @This();

author: HistoryAuthorType = .human,
origin: HistoryOriginType = .pane,
session_id: model.SessionId,
pane_id: PaneIdType,
location: TabLocationType,
sequence: u64,
workspace_path: []const u8,
cols: u16,
rows: u16,
provider: []const u8 = "",
tool_call_id: []const u8 = "",
