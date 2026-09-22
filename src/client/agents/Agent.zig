const data = @import("model");
const core = @import("telar-core");
const snapshot_support = @import("snapshot_support.zig");
const Agent = @This();

key: data.AgentKey,
location: core.TabLocation,
pane_index: u16,
workspace_label: [core.max_agent_workspace_label_bytes]u8 = undefined,
workspace_label_len: u8 = 0,
tab_label: [core.max_tab_label_bytes]u8 = undefined,
tab_label_len: u8 = 0,
session_title: [core.max_agent_session_title_bytes]u8 = undefined,
session_title_len: u8 = 0,
title_source: core.AgentTitleSource,
title_state: core.AgentTitleState,
cwd_label: [core.max_agent_cwd_label_bytes]u8 = undefined,
cwd_label_len: u8 = 0,
provider_name: [core.max_agent_provider_name_bytes]u8 = undefined,
provider_name_len: u8 = 0,
display_name: [core.max_agent_display_name_bytes]u8 = undefined,
display_name_len: u8 = 0,
icon: [core.max_agent_icon_bytes]u8 = undefined,
icon_len: u8 = 0,
attachments: core.AgentAttachmentMarkers,
provider: core.AgentProvider,
status: core.AgentStatus,
blocked_reason: core.AgentBlockedReason,
last_event: [core.max_agent_last_event_bytes]u8 = undefined,
last_event_len: u8 = 0,
/// Seconds the status had held when the runtime encoded this revision.
status_age_s: u32,

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

    return core.generic_display_name;
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

pub fn init(input: data.AgentInput) !Agent {
    var agent: Agent = .{
        .key = input.key,
        .location = input.location,
        .pane_index = input.pane_index,
        .title_source = input.title_source,
        .title_state = input.title_state,
        .provider = input.provider,
        .attachments = input.attachments,
        .status = input.status,
        .blocked_reason = input.blocked_reason,
        .status_age_s = input.status_age_s,
    };
    agent.workspace_label_len = try snapshot_support.copyLabel(&agent.workspace_label, input.workspace_label);
    agent.tab_label_len = try snapshot_support.copyLabel(&agent.tab_label, input.tab_label);
    agent.session_title_len = try snapshot_support.copyLabel(&agent.session_title, input.session_title);
    agent.cwd_label_len = try snapshot_support.copyLabel(&agent.cwd_label, input.cwd_label);
    agent.provider_name_len = try snapshot_support.copyLabel(&agent.provider_name, input.provider_name);
    agent.display_name_len = try snapshot_support.copyLabel(&agent.display_name, input.display_name);
    agent.icon_len = try snapshot_support.copyLabel(&agent.icon, input.icon);
    agent.last_event_len = try snapshot_support.copyLabel(&agent.last_event, input.last_event);

    return agent;
}

/// Borrows the last event line: the pending prompt while blocked, the last
/// tool call while working, a result summary when done. Empty when the
/// runtime has none.
///
/// ```zig
/// const event = agent.lastEvent();
/// ```
pub fn lastEvent(agent: *const Agent) []const u8 {
    return agent.last_event[0..agent.last_event_len];
}

/// Why the agent is blocked; `none` for every other status.
///
/// ```zig
/// if (agent.blockedReason() == .permission) drawPermissionIcon();
/// ```
pub fn blockedReason(agent: *const Agent) core.AgentBlockedReason {
    return agent.blocked_reason;
}

/// Seconds the current status had held when this revision was encoded.
/// Presentation adds the time elapsed since the snapshot arrived.
///
/// ```zig
/// const age = agent.statusAgeSeconds();
/// ```
pub fn statusAgeSeconds(agent: *const Agent) u32 {
    return agent.status_age_s;
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
