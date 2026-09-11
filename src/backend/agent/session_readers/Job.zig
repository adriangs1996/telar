const std = @import("std");
const WatchType = @import("../Watch.zig");
const Job = @This();

io: std.Io,
watch: WatchType
