const key_routing = @import("key_routing.zig");
const PaneCommand = @This();

target: key_routing.PaneTarget,
input: key_routing.Command,
