/// Late-bound text read. The pane resolves at encode time so a queued read
/// cannot borrow storage from a pane that exits before its send slot frees.
const PendingPaneText = @This();
const source_namespace = @import("response_queue.zig");
const pane_module = @import("../../pane/root.zig");
request_id: source_namespace.schema.RequestId,
pane: pane_module.PaneKey,
rows: u16,
source: source_namespace.schema.PaneTextSource,
