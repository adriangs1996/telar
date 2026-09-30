/// One stream of a child as it was kept.
const KeptStream = @This();

bytes: []u8 = &.{},
/// Bytes read before `bytes` that its tail no longer holds.
dropped: u64 = 0,
/// Line feeds read, kept or dropped.
lines: u64 = 0,
