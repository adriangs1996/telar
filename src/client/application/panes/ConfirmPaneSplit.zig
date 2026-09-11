const ConfirmPaneSplit = @This();
const source_namespace = @import("split_pane.zig");
requested: source_namespace.PaneSplit,
confirmed_pane: source_namespace.schema.PaneId,
confirmed_location: source_namespace.schema.TabLocation,
created: bool,
