const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const Version = @import("Version.zig");
const WorkspaceActivationSeed = @This();

pane_id: PaneIdType,
location: TabLocationType,
version_before: Version,
