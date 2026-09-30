//! When a limit was reached, on both clocks a reach needs: the monotonic
//! one paces notices and reports, the wall clock says when to a reader.

/// Monotonic milliseconds; never jumps with the wall clock.
awake_ms: i64,
/// Wall clock milliseconds since the epoch.
real_ms: i64,
