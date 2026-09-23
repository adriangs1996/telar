const std = @import("std");
const model = @import("model.zig");
const Counters = @import("Counters.zig");
const Submission = @This();

io: std.Io,
request: model.Request,
metrics: *Counters,
