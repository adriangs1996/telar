const PaneSnapshot = @This();
const source_namespace = @import("tabs.zig");
location: source_namespace.schema.TabLocation,
/// Borrowed only for synchronous reconciliation. Order is the canonical
/// display order used when a tab has no retained client layout.
panes: []const source_namespace.schema.PaneId,
