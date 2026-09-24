const Sampler = @import("Sampler.zig");
const Sample = @This();

sampler: Sampler,
duration_ns: u64,
captured_ns: u64,
