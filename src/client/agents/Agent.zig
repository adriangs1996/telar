const AgentKey = @import("AgentKey.zig");
const TabLocationType = @import("telar-core").TabLocation;
const max_agent_workspace_label_bytes_module = @import("telar-core").max_agent_workspace_label_bytes;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const max_agent_session_title_bytes_module = @import("telar-core").max_agent_session_title_bytes;
const AgentTitleSourceType = @import("telar-core").AgentTitleSource;
const AgentTitleStateType = @import("telar-core").AgentTitleState;
const max_agent_cwd_label_bytes_module = @import("telar-core").max_agent_cwd_label_bytes;
const max_agent_provider_name_bytes_module = @import("telar-core").max_agent_provider_name_bytes;
const max_agent_display_name_bytes_module = @import("telar-core").max_agent_display_name_bytes;
const max_agent_icon_bytes_module = @import("telar-core").max_agent_icon_bytes;
const AgentAttachmentMarkersType = @import("telar-core").AgentAttachmentMarkers;
const AgentProviderType = @import("telar-core").AgentProvider;
const AgentStatusType = @import("telar-core").AgentStatus;
const generic_display_name_module = @import("telar-core").generic_display_name;
const AgentInput = @import("AgentInput.zig");
const snapshot_support = @import("snapshot_support.zig");
const Agent = @This();

key: AgentKey,
location: TabLocationType,
pane_index: u16,
workspace_label: [max_agent_workspace_label_bytes_module]u8 = undefined,
workspace_label_len: u8 = 0,
tab_label: [max_tab_label_bytes_module]u8 = undefined,
tab_label_len: u8 = 0,
session_title: [max_agent_session_title_bytes_module]u8 = undefined,
session_title_len: u8 = 0,
title_source: AgentTitleSourceType,
title_state: AgentTitleStateType,
cwd_label: [max_agent_cwd_label_bytes_module]u8 = undefined,
cwd_label_len: u8 = 0,
provider_name: [max_agent_provider_name_bytes_module]u8 = undefined,
provider_name_len: u8 = 0,
display_name: [max_agent_display_name_bytes_module]u8 = undefined,
display_name_len: u8 = 0,
icon: [max_agent_icon_bytes_module]u8 = undefined,
icon_len: u8 = 0,
attachments: AgentAttachmentMarkersType,
provider: AgentProviderType,
status: AgentStatusType,

/// Manifest name of the provider ("claude"), or "agent" when the runtime
/// sent none because the provider is unknown.
///
/// ```zig
/// const name = agent.providerName();
/// ```
pub fn providerName(agent: *const Agent) []const u8 {
    if (agent.provider_name_len != 0) {
        return agent.provider_name[0..agent.provider_name_len];
    }

    return "agent";
}

/// Human label of the provider ("Claude Code"), or the generic label when
/// the runtime sent none.
///
/// ```zig
/// const label = agent.displayName();
/// ```
pub fn displayName(agent: *const Agent) []const u8 {
    if (agent.display_name_len != 0) {
        return agent.display_name[0..agent.display_name_len];
    }

    return generic_display_name_module;
}

/// Configured sidebar glyph; empty when the client should use its own
/// artwork for the provider.
///
/// ```zig
/// const glyph = agent.iconGlyph();
/// ```
pub fn iconGlyph(agent: *const Agent) []const u8 {
    return agent.icon[0..agent.icon_len];
}

pub fn init(input: AgentInput) !Agent {
    var agent: Agent = .{
        .key = input.key,
        .location = input.location,
        .pane_index = input.pane_index,
        .title_source = input.title_source,
        .title_state = input.title_state,
        .provider = input.provider,
        .attachments = input.attachments,
        .status = input.status,
    };
    agent.workspace_label_len = try snapshot_support.copyLabel(&agent.workspace_label, input.workspace_label);
    agent.tab_label_len = try snapshot_support.copyLabel(&agent.tab_label, input.tab_label);
    agent.session_title_len = try snapshot_support.copyLabel(&agent.session_title, input.session_title);
    agent.cwd_label_len = try snapshot_support.copyLabel(&agent.cwd_label, input.cwd_label);
    agent.provider_name_len = try snapshot_support.copyLabel(&agent.provider_name, input.provider_name);
    agent.display_name_len = try snapshot_support.copyLabel(&agent.display_name, input.display_name);
    agent.icon_len = try snapshot_support.copyLabel(&agent.icon, input.icon);

    return agent;
}

/// Borrows the workspace label owned by this replica entry.
///
/// ```zig
/// const label = agent.workspaceLabel();
/// ```
pub fn workspaceLabel(agent: *const Agent) []const u8 {
    return agent.workspace_label[0..agent.workspace_label_len];
}

/// Borrows the tab label owned by this replica entry.
///
/// ```zig
/// const label = agent.tabLabel();
/// ```
pub fn tabLabel(agent: *const Agent) []const u8 {
    return agent.tab_label[0..agent.tab_label_len];
}

/// Borrows the session title owned by this replica entry.
///
/// ```zig
/// const title = agent.sessionTitle();
/// ```
pub fn sessionTitle(agent: *const Agent) []const u8 {
    return agent.session_title[0..agent.session_title_len];
}

/// Borrows the cwd label owned by this replica entry.
///
/// ```zig
/// const cwd = agent.cwdLabel();
/// ```
pub fn cwdLabel(agent: *const Agent) []const u8 {
    return agent.cwd_label[0..agent.cwd_label_len];
}
