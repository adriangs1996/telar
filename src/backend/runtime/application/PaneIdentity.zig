const PaneKeyType = @import("../../pane/PaneKey.zig");
const TabLocationType = @import("telar-core").TabLocation;
const PaneIdentity = @This();

key: PaneKeyType,
location: TabLocationType,
socket_path: []const u8,
executable_path: []const u8,
