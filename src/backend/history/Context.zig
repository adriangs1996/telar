const std = @import("std");
const ChannelType = @import("Channel.zig");
const CountersType = @import("Counters.zig");
const Context = @This();

io: std.Io,
channel: *ChannelType,
metrics: *CountersType,
