//! A router's compile-time bounds: its bindings, their length, how many
//! physical keys it tracks at once and how long a partial binding waits.
const RouterLimits = @This();

max_bindings: usize,
max_keys: usize,
/// Physical keys held at once; a press beyond it is not leased.
max_physical_leases: usize,
/// How long a partial binding waits for its next key.
sequence_timeout_ns: u64,
