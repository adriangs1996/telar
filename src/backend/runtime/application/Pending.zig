const Pending = @This();
const source_namespace = @import("pane_search.zig");
const pane_mod = @import("../../pane/root.zig");
request_id: source_namespace.schema.RequestId,
pane: pane_mod.PaneKey,
cursor: pane_mod.TextSearch,
deadline_ns: i128,
