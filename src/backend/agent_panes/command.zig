const core = @import("telar-core");
const Prompt = @import("Prompt.zig");

pub const Command = union(enum) {
    prompt: Prompt,
    interrupt,
    resume_conversation: core.RecentConversation,
    approval: core.AgentApprovalDecision,
};
