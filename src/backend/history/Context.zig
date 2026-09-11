const Context = @This();
const std = @import("std");
const channel_mod = @import("channel_support.zig");
const metrics_mod = @import("metrics.zig");
io: std.Io,
channel: *channel_mod.Channel,
metrics: *metrics_mod.Counters,
