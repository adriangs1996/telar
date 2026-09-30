//! A client's reaches of one limit since its last report, so the runtime's
//! registry lists what every window ran into. Fire and forget: no reply.
const LimitReach = @import("../../LimitReach.zig");

reach: LimitReach,
/// Reaches folded into this report; at least one.
hits: u32,
