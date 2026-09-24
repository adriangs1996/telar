//! Bounded incremental reads of Claude session transcripts.

const core = @import("telar-core");
const agentfiles = @import("agentfiles");
const Job = @import("Job.zig");
const Completion = @import("../Completion.zig");

/// Example: `probe(job, &completion);`.
/// Reads what the transcript appended since the watch's offset; see
/// `agentfiles.claude.probe` for seeding, rewrites and the read bound.
pub fn probe(job: Job, completion: *Completion) void {
    var title_buffer: [core.max_agent_session_title_bytes]u8 = undefined;
    const result = agentfiles.claude.probe(job.io, job.watch.pathSlice(), job.watch.session.slice(), job.watch.offset, &title_buffer);
    if (result.offset) |offset| {
        completion.offset = offset;
    }

    if (result.title) |title| {
        completion.setTitle(title);
    }
}
