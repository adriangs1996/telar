const ConversationSelection = @import("ConversationSelection.zig");
const Approval = @import("telar-core").AgentApprovalDecision;

pub const Action = union(enum) {
    prompt: @import("telar-core").AgentSubmission,
    interrupt,
    resume_conversation: ConversationSelection,
    approval: Approval,
    query,
};
