const PaneMetadataCommit = @This();
const source_namespace = @import("types.zig");
pane_id: source_namespace.schema.PaneId,
kind: source_namespace.PaneMetadataKind,
display_changed: bool,
pane_metadata_revision: u64,
pane_foreground_revision: u64,
