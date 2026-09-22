const core = @import("telar-core");
const PaneKeyType = @import("../../pane/PaneKey.zig");
const PaneIdentity = @This();

key: PaneKeyType,
location: core.TabLocation,
socket_path: []const u8,
executable_path: []const u8,
