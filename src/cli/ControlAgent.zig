const core = @import("telar-core");
const control = @import("control.zig");
/// One decoded agent entry with its variable-length labels copied into owned
/// storage, so a snapshot can be inspected after the receive buffer is reused.
const Agent = @This();

pane_id: u64,
pane_generation: u64,
workspace_id: u64,
tab_id: u64,
pane_index: u16,
provider: core.AgentProvider,
status: core.AgentStatus,
workspace_label: [core.max_agent_workspace_label_bytes]u8 = undefined,
workspace_label_len: u8 = 0,
tab_label: [core.max_tab_label_bytes]u8 = undefined,
tab_label_len: u8 = 0,
title: [core.max_agent_session_title_bytes]u8 = undefined,
title_len: u8 = 0,
cwd_label: [core.max_agent_cwd_label_bytes]u8 = undefined,
cwd_label_len: u8 = 0,
provider_name: [core.max_agent_provider_name_bytes]u8 = undefined,
provider_name_len: u8 = 0,
blocked_reason: core.AgentBlockedReason = .none,
status_age_s: u32 = 0,
/// The tracked worktree the agent works in; zero when none.
work_tree: u64 = 0,
last_event: [core.max_agent_last_event_bytes]u8 = undefined,
last_event_len: u8 = 0,
plan_done: u16 = 0,
plan_total: u16 = 0,
plan_step: [core.max_agent_plan_step_bytes]u8 = undefined,
plan_step_len: u8 = 0,
final_message: [core.max_agent_final_message_bytes]u8 = undefined,
final_message_len: u16 = 0,

/// Manifest name of the provider; "unknown" when the runtime sent none.
pub fn providerLabel(self: *const Agent) []const u8 {
    if (self.provider_name_len != 0) {
        return self.provider_name[0..self.provider_name_len];
    }

    return "unknown";
}

pub fn workspaceLabel(self: *const Agent) []const u8 {
    return self.workspace_label[0..self.workspace_label_len];
}

pub fn tabLabel(self: *const Agent) []const u8 {
    return self.tab_label[0..self.tab_label_len];
}

pub fn titleSlice(self: *const Agent) []const u8 {
    return self.title[0..self.title_len];
}

pub fn cwdLabel(self: *const Agent) []const u8 {
    return self.cwd_label[0..self.cwd_label_len];
}

pub fn lastEvent(self: *const Agent) []const u8 {
    return self.last_event[0..self.last_event_len];
}

pub fn planStep(self: *const Agent) []const u8 {
    return self.plan_step[0..self.plan_step_len];
}

pub fn finalMessage(self: *const Agent) []const u8 {
    return self.final_message[0..self.final_message_len];
}

pub fn fromEntry(entry: core.AgentSnapshotEntry) Agent {
    var agent: Agent = .{
        .pane_id = core.raw(entry.pane_id),
        .pane_generation = entry.pane_generation,
        .workspace_id = core.raw(entry.location.workspace.workspace),
        .tab_id = core.raw(entry.location.tab_id),
        .pane_index = entry.pane_index,
        .provider = entry.provider,
        .status = entry.status,
    };
    agent.workspace_label_len = control.copyBounded(&agent.workspace_label, entry.workspace_label);
    agent.tab_label_len = control.copyBounded(&agent.tab_label, entry.tab_label);
    agent.title_len = control.copyBounded(&agent.title, entry.session_title);
    agent.cwd_label_len = control.copyBounded(&agent.cwd_label, entry.cwd_label);
    agent.provider_name_len = control.copyBounded(&agent.provider_name, entry.provider_name);
    agent.blocked_reason = entry.blocked_reason;
    agent.status_age_s = entry.status_age_s;
    agent.work_tree = core.raw(entry.work_tree);
    agent.last_event_len = control.copyBounded(&agent.last_event, entry.last_event);
    agent.plan_done = entry.plan_done;
    agent.plan_total = entry.plan_total;
    agent.plan_step_len = control.copyBounded(&agent.plan_step, entry.plan_step);
    const message_len = @min(entry.final_message.len, agent.final_message.len);
    @memcpy(agent.final_message[0..message_len], entry.final_message[0..message_len]);
    agent.final_message_len = @intCast(message_len);
    return agent;
}
