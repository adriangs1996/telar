const core = @import("telar-core");

pane_id: core.PaneId,
pane_generation: u64,
attachment_generation: u64,
composer_content_revision: u64,
location: core.TabLocation,
text: []const u8,
images: core.AgentImagePaths = .{},
options: core.AgentOptions,
