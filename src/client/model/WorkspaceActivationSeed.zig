const WorkspaceActivationSeed = @This();
const source_namespace = @import("types.zig");
const Version = @import("Version.zig");
pane_id: source_namespace.schema.PaneId,
location: source_namespace.schema.TabLocation,
version_before: Version,
