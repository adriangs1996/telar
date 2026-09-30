//! One row of the runtime's limit registry as the wire carries it.
const LimitReach = @import("../../LimitReach.zig");
const LimitOrigin = @import("../../LimitOrigin.zig").LimitOrigin;

/// The limit and the last amount asked for.
reach: LimitReach,
origin: LimitOrigin,
hits: u64,
/// Wall clock of the last reach, in milliseconds since the epoch.
last_ms: i64,
