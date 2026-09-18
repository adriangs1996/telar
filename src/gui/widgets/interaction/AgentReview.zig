const core = @import("telar-core");
const ThreadView = @import("telar-client").ThreadView;
const Review = @This();

pane_id: core.PaneId,
generation: u64,
approval_id: u64,

/// Rendering and input use the same current approval authority.
/// Example: `const pending = review.request(thread) orelse return;`
pub fn request(review: Review, thread: ThreadView) ?*const core.AgentApprovalRequest {
    if (thread.kind != .agent or review.pane_id != thread.pane_id or review.generation != thread.attachment_generation) {
        return null;
    }

    const snapshot = thread.transcript orelse return null;
    const pending = if (snapshot.pending_approval) |*value| value else return null;
    return if (pending.id == review.approval_id) pending else null;
}
