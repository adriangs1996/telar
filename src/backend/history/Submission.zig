const std = @import("std");
const model = @import("model.zig");
const CountersType = @import("Counters.zig");
const Submission = @This();

io: std.Io,
request: model.Request,
metrics: *CountersType,
