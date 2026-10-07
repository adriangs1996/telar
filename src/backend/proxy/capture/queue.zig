//! Bounded pointer-transfer queue for captured exchange halves.

const core = @import("telar-core");

pub const capacity = 256;
pub const capacity_limit = core.Limit.declare("proxy.capture.queue_capacity", "halves", capacity);
