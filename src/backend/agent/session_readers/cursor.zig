//! Read-only adapter for Cursor Agent's chat metadata.

const core = @import("telar-core");
const agentfiles = @import("agentfiles");
const Job = @import("Job.zig");
const Completion = @import("../Completion.zig");

/// Example: `probe(job, &completion);`.
/// Reports the chat's current title; nothing while the file is missing or
/// half written. Metadata without a title reports an empty one, which
/// clears an earlier agent title.
pub fn probe(job: Job, completion: *Completion) void {
    var title_buffer: [core.max_agent_session_title_bytes]u8 = undefined;
    const title = agentfiles.cursor.chatTitle(job.io, job.watch.pathSlice(), job.watch.session.slice(), &title_buffer) orelse return;
    completion.setTitle(title);
}
