const RequestIdType = @import("telar-core").RequestId;
const PaneKeyType = @import("../../pane/PaneKey.zig");
const PaneTextSourceType = @import("telar-core").PaneTextSource;
/// Late-bound text read. The pane resolves at encode time so a queued read
/// cannot borrow storage from a pane that exits before its send slot frees.
const PendingPaneText = @This();

request_id: RequestIdType,
pane: PaneKeyType,
rows: u16,
source: PaneTextSourceType,
