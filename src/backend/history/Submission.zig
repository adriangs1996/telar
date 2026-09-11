const Submission = @This();
const std = @import("std");
const model = @import("model.zig");
const metrics_mod = @import("metrics.zig");
io: std.Io,
request: model.Request,
metrics: *metrics_mod.Counters,
