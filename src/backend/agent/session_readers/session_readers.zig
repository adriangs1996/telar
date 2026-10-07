//! Provider-specific reads of session files on the observation worker.

const Job = @import("Job.zig");
const Completion = @import("../Completion.zig");
const claude = @import("claude.zig");
const codex = @import("codex.zig");
const cursor = @import("cursor.zig");

/// Runs on a worker: never touches runtime state.
///
/// ```zig
/// const completion = probe(job);
/// ```
pub fn probe(job: Job) Completion {
    var completion: Completion = .{ .key = job.watch.key, .offset = job.watch.offset };
    switch (job.watch.kind) {
        .claude_transcript => claude.probe(job, &completion),
        .codex_state => codex.probe(job, &completion),
        .cursor_meta => cursor.probe(job, &completion),
    }

    return completion;
}
