const std = @import("std");
const Channel = @import("Channel.zig");
const Counters = @import("Counters.zig");
const Context = @This();

io: std.Io,
channel: *Channel,
metrics: *Counters,
