const SamplerType = @import("Sampler.zig");
const Resources = @This();

sampler: *SamplerType,
pending: *bool,
