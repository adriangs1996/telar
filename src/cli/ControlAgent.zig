const AgentProviderType = @import("telar-core").AgentProvider;
const AgentStatusType = @import("telar-core").AgentStatus;
const max_agent_workspace_label_bytes_module = @import("telar-core").max_agent_workspace_label_bytes;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const max_agent_session_title_bytes_module = @import("telar-core").max_agent_session_title_bytes;
const max_agent_cwd_label_bytes_module = @import("telar-core").max_agent_cwd_label_bytes;
const max_agent_provider_name_bytes_module = @import("telar-core").max_agent_provider_name_bytes;
const AgentSnapshotEntryType = @import("telar-core").AgentSnapshotEntry;
const raw_module = @import("telar-core").raw;
const control = @import("control.zig");
/// One decoded agent entry with its variable-length labels copied into owned
/// storage, so a snapshot can be inspected after the receive buffer is reused.
const Agent = @This();

pane_id: u64,
pane_generation: u64,
workspace_id: u64,
tab_id: u64,
pane_index: u16,
provider: AgentProviderType,
status: AgentStatusType,
workspace_label: [max_agent_workspace_label_bytes_module]u8 = undefined,
workspace_label_len: u8 = 0,
tab_label: [max_tab_label_bytes_module]u8 = undefined,
tab_label_len: u8 = 0,
title: [max_agent_session_title_bytes_module]u8 = undefined,
title_len: u8 = 0,
cwd_label: [max_agent_cwd_label_bytes_module]u8 = undefined,
cwd_label_len: u8 = 0,
provider_name: [max_agent_provider_name_bytes_module]u8 = undefined,
provider_name_len: u8 = 0,

/// Manifest name of the provider; "unknown" when the runtime sent none.
pub fn providerLabel(agent: *const Agent) []const u8 {
    if (agent.provider_name_len != 0) {
        return agent.provider_name[0..agent.provider_name_len];
    }

    return "unknown";
}

pub fn workspaceLabel(agent: *const Agent) []const u8 {
    return agent.workspace_label[0..agent.workspace_label_len];
}

pub fn tabLabel(agent: *const Agent) []const u8 {
    return agent.tab_label[0..agent.tab_label_len];
}

pub fn titleSlice(agent: *const Agent) []const u8 {
    return agent.title[0..agent.title_len];
}

pub fn cwdLabel(agent: *const Agent) []const u8 {
    return agent.cwd_label[0..agent.cwd_label_len];
}

pub fn fromEntry(entry: AgentSnapshotEntryType) Agent {
    var agent: Agent = .{
        .pane_id = raw_module(entry.pane_id),
        .pane_generation = entry.pane_generation,
        .workspace_id = raw_module(entry.location.workspace.workspace),
        .tab_id = raw_module(entry.location.tab_id),
        .pane_index = entry.pane_index,
        .provider = entry.provider,
        .status = entry.status,
    };
    agent.workspace_label_len = control.copyBounded(&agent.workspace_label, entry.workspace_label);
    agent.tab_label_len = control.copyBounded(&agent.tab_label, entry.tab_label);
    agent.title_len = control.copyBounded(&agent.title, entry.session_title);
    agent.cwd_label_len = control.copyBounded(&agent.cwd_label, entry.cwd_label);
    agent.provider_name_len = control.copyBounded(&agent.provider_name, entry.provider_name);
    return agent;
}
