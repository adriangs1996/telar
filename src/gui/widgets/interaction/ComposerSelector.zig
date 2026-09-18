const core = @import("telar-core");

pane_id: core.PaneId,
kind: enum { model, effort, access, recent },
catalog_revision: u64,
options_revision: u64,
