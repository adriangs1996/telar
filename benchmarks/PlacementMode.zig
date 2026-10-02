/// Where the placement experiment puts an idle-delivery fixture's large
/// allocations. `baseline` leaves them to the backing allocator, `shift` moves
/// each by the same offset, `stagger` gives each a different offset inside one
/// window, and `pack` carves them back to back from one region.
pub const PlacementMode = enum {
    baseline,
    shift,
    stagger,
    pack,
};
