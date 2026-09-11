const Resources = @This();
const system_metrics = @import("system_metrics.zig");
sampler: *system_metrics.Sampler,
pending: *bool,
