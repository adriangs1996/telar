const Approval = @import("telar-core").AgentApprovalDecision;

pub const Action = union(enum) {
    prompt: @import("telar-core").AgentSubmission,
    interrupt,
    resume_conversation: u8,
    approval: Approval,
    query,
};
