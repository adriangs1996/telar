const core = @import("telar-core");
const PaneKey = @import("../../pane/PaneKey.zig");
const Cursor = @import("../../pane/Cursor.zig");
const PendingSearch = @This();

request_id: core.RequestId,
pane: PaneKey,
cursor: Cursor,
deadline_ns: i128,
