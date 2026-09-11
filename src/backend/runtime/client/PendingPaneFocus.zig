const RequestIdType = @import("telar-core").RequestId;
const PaneIdType = @import("telar-core").PaneId;
const ClientKey = @import("../../history/ClientKey.zig");
const PendingPaneFocus = @This();

request_id: RequestIdType,
pane_id: PaneIdType,
pane_generation: u64,
target: ClientKey,
