const AgentKey = @import("AgentKey.zig");
const TabLocationType = @import("telar-core").TabLocation;
const AgentTitleSourceType = @import("telar-core").AgentTitleSource;
const AgentTitleStateType = @import("telar-core").AgentTitleState;
const AgentProviderType = @import("telar-core").AgentProvider;
const AgentAttachmentMarkersType = @import("telar-core").AgentAttachmentMarkers;
const AgentStatusType = @import("telar-core").AgentStatus;
const AgentInput = @This();

key: AgentKey,
location: TabLocationType,
pane_index: u16,
workspace_label: []const u8 = "",
tab_label: []const u8 = "",
session_title: []const u8 = "",
title_source: AgentTitleSourceType = .telar,
title_state: AgentTitleStateType = .placeholder,
cwd_label: []const u8 = "",
provider: AgentProviderType,
provider_name: []const u8 = "",
display_name: []const u8 = "",
icon: []const u8 = "",
attachments: AgentAttachmentMarkersType = .none,
status: AgentStatusType,
