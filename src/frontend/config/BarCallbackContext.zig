const CallbackContext = @import("telar-client").CallbackContext;
const BarTime = @import("BarTime.zig");
const BarMetrics = @import("BarMetrics.zig");
const BarCallbackContext = @This();

client: CallbackContext,
time: BarTime,
metrics: ?BarMetrics,
command_output: ?[]const u8 = null,
/// Window title of the focused pane in the active tab, empty when unset.
pane_title: []const u8 = "",
