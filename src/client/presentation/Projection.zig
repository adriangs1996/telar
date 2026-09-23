const data = @import("model");
const core = @import("telar-core");
const PresentationIngress = @import("PresentationIngress.zig");
const hints_support = @import("../input/hints_support.zig");
const CopyProjection = @import("../workspace/CopyProjection.zig");
const ThreadView = @import("ThreadView.zig");
const Projection = @This();

version: data.Version,
geometry: data.Region,
presentation_ingress: PresentationIngress = .{},
/// The client model, borrowed for one synchronous preparation.
model: *const data.ClientModel,
/// The active tab's slot, null during bootstrap and workspace handoff.
tab: ?usize,
/// The active tab's layout inside `geometry`, from the model's snapshot
/// cache; null with `tab`. Every renderer of one frame reads this copy.
layout: ?*const data.LayoutSnapshot,
agents: *const data.AgentSnapshot,
sidebar_animation_frame: u8,
notifications: *const data.Center,
workspaces: *const data.WorkspaceListSnapshot,
prompt: ?data.Prompt,
history: *const data.HistoryPaletteState,
suggestion: *const data.SuggestionState,
path_completion: *const data.PathCompletionState,
proxy_tls_active: bool,
proxy_tls_scope: core.ProxyScope,
proxy_system_trusted: bool,
system_metrics: ?data.SystemMetrics,
bar_state: *const data.BarsState,
status_mode: hints_support.Mode,
diagnostic: ?[]const u8,
copy: ?CopyProjection,
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
pub fn threadView(projection: *const Projection, pane_id: core.PaneId) ?ThreadView {
    const slot = projection.tab orelse return null;
    const model = projection.model;
    const pane = model.panes.findInConst(model.tabs.location[slot].tab_id, pane_id) orelse return null;
    var thread = ThreadView.capture(model, projection.agents, pane_id) orelse return null;
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
