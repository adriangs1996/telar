const data = @import("model");
const BarMetrics = @import("BarMetrics.zig");
const BarCallbackContext = @This();

client: data.CallbackContext,
time: BarTime,
metrics: ?BarMetrics,
command_output: ?[]const u8 = null,
/// Window title of the focused pane in the active tab, empty when unset.
pane_title: []const u8 = "",

const BarTime = struct {
    unix_seconds: i64,
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    weekday: u8,
};
