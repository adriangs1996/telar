const core = @import("telar-core");
const PaneKeyType = @import("../../pane/PaneKey.zig");
/// Late-bound text read. The pane resolves at encode time so a queued read
/// cannot borrow storage from a pane that exits before its send slot frees.
const PendingPaneText = @This();

request_id: core.RequestId,
pane: PaneKeyType,
rows: u16,
source: core.PaneTextSource,
