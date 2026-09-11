const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const PaneSnapshot = @This();

location: TabLocationType,
/// Borrowed only for synchronous reconciliation. Order is the canonical
/// display order used when a tab has no retained client layout.
panes: []const PaneIdType,
