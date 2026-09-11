const PaneIdType = @import("telar-core").PaneId;
const types = @import("types.zig");
const PaneMetadataCommit = @This();

pane_id: PaneIdType,
kind: types.PaneMetadataKind,
display_changed: bool,
pane_metadata_revision: u64,
pane_foreground_revision: u64,
