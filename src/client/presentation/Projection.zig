const data = @import("model");
const core = @import("telar-core");
const VersionType = @import("../model/Version.zig");
const PresentationIngress = @import("PresentationIngress.zig");
const MultiplexerModel = @import("../workspace/MultiplexerModel.zig");
const TabsModel = @import("../workspace/TabsModel.zig");
const SnapshotType = @import("../agents/AgentSnapshot.zig");
const WorkspaceListSnapshot = @import("../workspace/WorkspaceListSnapshot.zig");
const HistoryPaletteState = @import("../model/HistoryPaletteState.zig");
const SuggestionState = @import("../model/SuggestionState.zig");
const SystemMetricsType = @import("../model/SystemMetrics.zig");
const StateType = @import("../bars/State.zig");
const hints_support = @import("../input/hints_support.zig");
const CopyProjectionType = @import("../workspace/CopyProjection.zig");
const ThreadViewType = @import("ThreadView.zig");
const Projection = @This();

version: VersionType,
geometry: data.Region,
presentation_ingress: PresentationIngress = .{},
model: ?*const MultiplexerModel,
tabs: *const TabsModel,
agents: *const SnapshotType,
sidebar_animation_frame: u8,
notifications: *const data.Center,
workspaces: *const WorkspaceListSnapshot,
prompt: ?data.Prompt,
history: *const HistoryPaletteState,
suggestion: *const SuggestionState,
path_completion: *const data.PathCompletionState,
proxy_tls_active: bool,
proxy_tls_scope: core.ProxyScope,
proxy_system_trusted: bool,
system_metrics: ?SystemMetricsType,
bar_state: *const StateType,
status_mode: hints_support.Mode,
diagnostic: ?[]const u8,
copy: ?CopyProjectionType,
sidebar_visible: bool,
sidebar_width: u16,
workspace_list_collapsed: bool,
host_capabilities: data.HostCapabilities,
host_size: core.TerminalSize,
/// Configured host window title template; empty leaves the host alone.
window_title_template: []const u8 = "",

/// Borrows the thread view for one pane of the active model.
///
/// ```zig
/// const thread = projection.threadView(pane_id) orelse return;
/// ```
pub fn threadView(projection: *const Projection, pane_id: core.PaneId) ?ThreadViewType {
    const model = projection.model orelse return null;

    var thread = ThreadViewType.capture(model, projection.agents, pane_id) orelse return null;
    const pane = model.findConst(pane_id) orelse return null;
    const workspace_id = switch (pane.location.workspace) {
        .workspace => |id| id,
        .worktree => return thread,
    };
    for (0..projection.workspaces.count) |index| {
        if (projection.workspaces.workspaceAt(index) == workspace_id) {
            thread.branch = projection.workspaces.branchAt(index);
            break;
        }
    }

    return thread;
}
