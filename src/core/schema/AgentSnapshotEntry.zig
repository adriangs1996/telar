const AgentSnapshotEntry = @This();
const id = @import("id.zig");
const TabLocation = @import("TabLocation.zig");
const source_namespace = @import("types.zig");
pane_id: id.PaneId,
pane_generation: u64,
location: TabLocation = .{
    .workspace = .{ .workspace = .invalid },
    .tab_id = .invalid,
},
/// One-based position among the currently open panes in this tab.
pane_index: u16 = 0,
process_id: u32,
session_id: [16]u8,
workspace_label: []const u8 = "",
tab_label: []const u8 = "",
session_title: []const u8 = "",
title_source: source_namespace.AgentTitleSource = .telar,
title_state: source_namespace.AgentTitleState = .placeholder,
cwd_label: []const u8 = "",
provider: source_namespace.AgentProvider,
/// Manifest name for `provider` ("claude"); empty only for `unknown`.
provider_name: []const u8 = "",
/// Human label for `provider` ("Claude Code"); empty only for `unknown`.
display_name: []const u8 = "",
/// Configured sidebar glyph; empty selects the client's own artwork.
icon: []const u8 = "",
attachments: source_namespace.AgentAttachmentMarkers = .none,
status: source_namespace.AgentStatus,
source: source_namespace.AgentSource,
authority: source_namespace.AgentAuthority,
confidence: u8,
sequence: u64,
observed_at_ms: i64,
expires_at_ms: i64,
