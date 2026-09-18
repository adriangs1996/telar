const core = @import("telar-core");

pub const Command = union(enum) {
    prompt: @import("Prompt.zig"),
    interrupt,
    resume_conversation: core.RecentConversation,
    approval: core.AgentApprovalDecision,
};
