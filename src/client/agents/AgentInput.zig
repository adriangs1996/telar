const AgentInput = @This();
const AgentKey = @import("AgentKey.zig");
const source_namespace = @import("snapshot_support.zig");
key: AgentKey,
location: source_namespace.schema.TabLocation,
pane_index: u16,
workspace_label: []const u8 = "",
tab_label: []const u8 = "",
session_title: []const u8 = "",
title_source: source_namespace.schema.AgentTitleSource = .telar,
title_state: source_namespace.schema.AgentTitleState = .placeholder,
cwd_label: []const u8 = "",
provider: source_namespace.schema.AgentProvider,
provider_name: []const u8 = "",
display_name: []const u8 = "",
icon: []const u8 = "",
attachments: source_namespace.schema.AgentAttachmentMarkers = .none,
status: source_namespace.schema.AgentStatus,
