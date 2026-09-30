//! How often the tap reached each of its limits since the runtime started.
//! The worker threads count; the runtime's event loop reports what grew.
const TapLimitCounts = @This();

/// Frames dropped at a queue holding `queue_depth`.
dropped_queue: u64 = 0,
/// Frames dropped past `max_queued_bytes`.
dropped_bytes: u64 = 0,
/// Replies that missed `reply_timeout_ms`.
timeouts: u64 = 0,
/// Workers disabled after `restart_limit` restarts.
disabled: u64 = 0,
