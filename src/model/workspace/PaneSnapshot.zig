const core = @import("telar-core");

location: core.TabLocation,
/// Borrowed only for synchronous reconciliation. Order is the canonical
/// display order used when a tab has no retained client layout.
panes: []const core.PaneId,
