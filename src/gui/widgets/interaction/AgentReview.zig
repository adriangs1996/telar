const client = @import("telar-client");
const core = @import("telar-core");
const Review = @This();

pane_id: core.PaneId,
generation: u64,
approval_id: u64,

/// Rendering and input use the same current approval authority.
/// Example: `const pending = review.request(thread) orelse return;`
pub fn request(self: Review, thread: client.ThreadView) ?*const core.AgentApprovalRequest {
    if (thread.kind != .agent or self.pane_id != thread.pane_id or self.generation != thread.attachment_generation) {
        return null;
    }

    const snapshot = thread.transcript orelse return null;
    const pending = if (snapshot.pending_approval) |*value| value else return null;
    return if (pending.id == self.approval_id) pending else null;
}
