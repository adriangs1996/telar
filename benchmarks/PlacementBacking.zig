/// The allocator under the placement experiment: the benchmark's own debug
/// allocator, as every other case uses, or libc's.
pub const PlacementBacking = enum {
    debug,
    libc,
};
