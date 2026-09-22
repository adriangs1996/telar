const core = @import("telar-core");
const Version = @import("Version.zig");
const WorkspaceActivationSeed = @This();

pane_id: core.PaneId,
location: core.TabLocation,
version_before: Version,
