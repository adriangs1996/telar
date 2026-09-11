const RequestIdType = @import("telar-core").RequestId;
const PaneKeyType = @import("../../pane/PaneKey.zig");
const Cursor = @import("../../pane/Cursor.zig");
const Pending = @This();

request_id: RequestIdType,
pane: PaneKeyType,
cursor: Cursor,
deadline_ns: i128,
