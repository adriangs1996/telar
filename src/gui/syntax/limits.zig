const core = @import("telar-core");

/// Most fragments one highlighting job may stitch before it gives up.
pub const fragments = 64;
/// Longest a highlighting job may run, in milliseconds.
pub const job_ms = 1000;

pub const fragments_limit = core.Limit.declare("syntax.fragments", "highlighted fragments", fragments);
pub const job_limit = core.Limit.declare("syntax.job_ms", "milliseconds", job_ms);
