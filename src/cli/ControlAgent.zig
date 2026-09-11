/// One decoded agent entry with its variable-length labels copied into owned
/// storage, so a snapshot can be inspected after the receive buffer is reused.
const Agent = @This();
const source_namespace = @import("control.zig");
pane_id: u64,
pane_generation: u64,
workspace_id: u64,
tab_id: u64,
pane_index: u16,
provider: source_namespace.schema.AgentProvider,
status: source_namespace.schema.AgentStatus,
workspace_label: [source_namespace.schema.max_agent_workspace_label_bytes]u8 = undefined,
workspace_label_len: u8 = 0,
tab_label: [source_namespace.schema.max_tab_label_bytes]u8 = undefined,
tab_label_len: u8 = 0,
title: [source_namespace.schema.max_agent_session_title_bytes]u8 = undefined,
title_len: u8 = 0,
cwd_label: [source_namespace.schema.max_agent_cwd_label_bytes]u8 = undefined,
cwd_label_len: u8 = 0,
provider_name: [source_namespace.schema.max_agent_provider_name_bytes]u8 = undefined,
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

pub fn fromEntry(entry: source_namespace.schema.AgentSnapshotEntry) Agent {
    var agent: Agent = .{
        .pane_id = source_namespace.schema.id.raw(entry.pane_id),
        .pane_generation = entry.pane_generation,
        .workspace_id = source_namespace.schema.id.raw(entry.location.workspace.workspace),
        .tab_id = source_namespace.schema.id.raw(entry.location.tab_id),
        .pane_index = entry.pane_index,
        .provider = entry.provider,
        .status = entry.status,
    };
    agent.workspace_label_len = source_namespace.copyBounded(&agent.workspace_label, entry.workspace_label);
    agent.tab_label_len = source_namespace.copyBounded(&agent.tab_label, entry.tab_label);
    agent.title_len = source_namespace.copyBounded(&agent.title, entry.session_title);
    agent.cwd_label_len = source_namespace.copyBounded(&agent.cwd_label, entry.cwd_label);
    agent.provider_name_len = source_namespace.copyBounded(&agent.provider_name, entry.provider_name);
    return agent;
}
