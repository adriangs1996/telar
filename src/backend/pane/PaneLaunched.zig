const PaneKey = @import("PaneKey.zig");
const TabLocationType = @import("telar-core").TabLocation;
/// Fact produced when the runtime owns a discoverable pane and its actors.
const PaneLaunched = @This();

key: PaneKey,
location: TabLocationType,
