//! Bounds of one change-review highlighting job. A job that reaches one keeps
//! the roles it has, leaves the rest plain and returns the limit it reached.
const syntaxhl = @import("syntaxhl");
const core = @import("telar-core");

/// Most fragments (one side of one hunk) a highlighting job highlights.
pub const fragments = 1024;
pub const fragments_limit = core.Limit.declare("syntax.job_fragments", "highlighted fragments", fragments);

/// Longest a highlighting job admits new fragments, in milliseconds.
pub const job_ms = 1000;
pub const job_ms_limit = core.Limit.declare("syntax.job_ms", "milliseconds", job_ms);

/// Largest source a job highlights, in bytes; a larger one stays plain.
pub const source_bytes_limit = core.Limit.declare("syntax.source_bytes", "bytes", syntaxhl.limits.source_bytes);

comptime {
    if (syntaxhl.limits.source_bytes < core.change_review.max_patch_bytes) {
        @compileError("syntaxhl.limits.source_bytes must hold core.change_review.max_patch_bytes");
    }
}
