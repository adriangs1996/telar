//! Read-only adapter for the Codex thread-name database.

const core = @import("telar-core");
const agentfiles = @import("agentfiles");
const Job = @import("Job.zig");
const Completion = @import("../Completion.zig");

/// Example: `probe(job, &completion);`.
/// Reports the thread's current name; nothing when the database is busy or
/// missing, or the thread is not inserted yet. A NULL name reports an empty
/// title, which clears an earlier agent title.
pub fn probe(job: Job, completion: *Completion) void {
    var title_buffer: [core.max_agent_session_title_bytes]u8 = undefined;
    const name = agentfiles.codex.threadName(job.watch.pathSlice(), job.watch.session.slice(), &title_buffer) orelse return;
    completion.setTitle(name);
}
