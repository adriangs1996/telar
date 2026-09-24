//! A router's compile-time bounds: its bindings, their length, its buffers,
//! how many physical keys it tracks at once and how long it waits.
const RouterLimits = @This();

max_bindings: usize,
max_keys: usize,
input_capacity: usize,
held_capacity: usize,
/// Physical keys held at once; a press beyond it is not leased.
max_physical_leases: usize,
/// How long a lone Escape waits for the rest of a sequence before it is a key.
escape_timeout_ns: u64,
/// How long a partial binding waits for its next key.
sequence_timeout_ns: u64,
