const Stats = @This();

/// Frames actually drawn.
drawn: u64 = 0,
/// Frames that had to wait for the budget. The ratio against `drawn`
/// is how much of the session was a burst.
throttled: u64 = 0,
/// Messages that were folded into a frame rather than getting one of
/// their own. This is the number the throttle exists to produce.
absorbed: u64 = 0,
/// Messages dropped as superseded.
dropped: u64 = 0,
