const std = @import("std");
const Probe = @import("../../workspace/Probe.zig");
const Job = @This();

io: std.Io,
request: Probe,
