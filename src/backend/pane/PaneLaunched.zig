/// Fact produced when the runtime owns a discoverable pane and its actors.
const PaneLaunched = @This();
const PaneKey = @import("PaneKey.zig");
const source_namespace = @import("root.zig");
key: PaneKey,
location: source_namespace.schema.TabLocation,
