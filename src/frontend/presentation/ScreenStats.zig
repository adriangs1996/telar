const Stats = @This();

/// Cells actually written. The number to watch: if idle frames are not
/// near zero, something is being redrawn that did not change.
cells: usize = 0,
/// Candidate cells compared. This should follow the damage size, not
/// the terminal size, for incremental frames.
scanned: usize = 0,
bytes: usize = 0,
graphics_bytes: usize = 0,
