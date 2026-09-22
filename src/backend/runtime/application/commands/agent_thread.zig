const core = @import("telar-core");
const ConversationSelection = @import("ConversationSelection.zig");

pub const Action = union(enum) {
    prompt: core.AgentSubmission,
    interrupt,
    resume_conversation: ConversationSelection,
    approval: core.AgentApprovalDecision,
    query,
};
