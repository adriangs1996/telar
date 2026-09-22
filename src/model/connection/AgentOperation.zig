const core = @import("telar-core");

pane_id: core.PaneId,
pane_generation: u64,
attachment_generation: u64,
location: core.TabLocation,
composer_content_revision: ?u64 = null,
