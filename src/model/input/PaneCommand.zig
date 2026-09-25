const key_routing = @import("key_routing.zig");
const core = @import("telar-core");
const PaneCommand = @This();

target: KeyRoutingPaneTarget,
input: key_routing.Command,

const KeyRoutingPaneTarget = union(enum) {
    current,
    lease: core.PaneId,
};
