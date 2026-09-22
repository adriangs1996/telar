const core = @import("telar-core");
const PaneKey = @import("PaneKey.zig");
/// Fact produced when the runtime owns a discoverable pane and its actors.
const PaneLaunched = @This();

key: PaneKey,
location: core.TabLocation,

kind: core.PaneKind = .terminal,
