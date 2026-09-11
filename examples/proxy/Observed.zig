/// What one direction saw. Bodies are capped by the caller's buffer.
const Observed = @This();

frames: usize = 0,
headers: usize = 0,
data_bytes: u64 = 0,
truncated: bool = false,
