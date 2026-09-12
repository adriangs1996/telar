const VersionType = @import("../model/Version.zig");
const RegionType = @import("../workspace/Region.zig");
const PresentationIngress = @import("PresentationIngress.zig");
const MultiplexerModel = @import("../workspace/MultiplexerModel.zig");
const TabsModel = @import("../workspace/TabsModel.zig");
const SnapshotType = @import("../agents/AgentSnapshot.zig");
const CenterType = @import("../notifications/Center.zig");
const WorkspaceListSnapshot = @import("../workspace/WorkspaceListSnapshot.zig");
const PromptType = @import("../model/Prompt.zig");
const HistoryPaletteState = @import("../model/HistoryPaletteState.zig");
const SuggestionState = @import("../model/SuggestionState.zig");
const ProxyScopeType = @import("telar-core").ProxyScope;
const SystemMetricsType = @import("../model/SystemMetrics.zig");
const StateType = @import("../bars/State.zig");
const hints_support = @import("../input/hints_support.zig");
const CopyProjectionType = @import("../workspace/CopyProjection.zig");
const HostCapabilitiesType = @import("../model/HostCapabilities.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const ThreadViewType = @import("ThreadView.zig");
const PaneIdType = @import("telar-core").PaneId;
const Projection = @This();

version: VersionType,
geometry: RegionType,
presentation_ingress: PresentationIngress = .{},
model: ?*const MultiplexerModel,
tabs: *const TabsModel,
agents: *const SnapshotType,
sidebar_animation_frame: u8,
notifications: *const CenterType,
workspaces: *const WorkspaceListSnapshot,
prompt: ?PromptType,
history: *const HistoryPaletteState,
suggestion: *const SuggestionState,
proxy_tls_active: bool,
proxy_tls_scope: ProxyScopeType,
proxy_system_trusted: bool,
system_metrics: ?SystemMetricsType,
bar_state: *const StateType,
status_mode: hints_support.Mode,
diagnostic: ?[]const u8,
copy: ?CopyProjectionType,
sidebar_visible: bool,
sidebar_width: u16,
workspace_list_collapsed: bool,
host_capabilities: HostCapabilitiesType,
host_size: TerminalSizeType,
/// Configured host window title template; empty leaves the host alone.
window_title_template: []const u8 = "",

/// Borrows the thread view for one pane of the active model.
///
/// ```zig
/// const thread = projection.threadView(pane_id) orelse return;
/// ```
pub fn threadView(projection: *const Projection, pane_id: PaneIdType) ?ThreadViewType {
    const model = projection.model orelse return null;

    return ThreadViewType.capture(model, projection.agents, pane_id);
}
