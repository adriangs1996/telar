const core = @import("telar-core");
const PaneKeyType = @import("../../pane/PaneKey.zig");
const Cursor = @import("../../pane/Cursor.zig");
const Pending = @This();

request_id: core.RequestId,
pane: PaneKeyType,
cursor: Cursor,
deadline_ns: i128,
