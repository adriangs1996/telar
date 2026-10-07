const core = @import("telar-core");
const model_data = @import("../model.zig");

pane_id: core.PaneId,
kind: model_data.PaneMetadataKind,
display_changed: bool,
pane_metadata_revision: u64,
pane_foreground_revision: u64,
