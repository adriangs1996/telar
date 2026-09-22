const client = @import("telar-client");
const data = @import("model");
const core = @import("telar-core");
const CompositorType = @import("../../workspace/Compositor.zig");
const view = @import("view.zig");
const RenderInput = @This();

tabs: ?*const client.TabsModel = null,
model: *const client.MultiplexerModel,
compositor: ?*const CompositorType = null,
agents: *const client.AgentSnapshot = &view.empty_agent_snapshot,
sidebar_animation_frame: u8 = 0,
notifications: *const data.Center = &view.empty_notifications,
workspaces: *const client.WorkspaceListSnapshot = &view.empty_workspace_list,
prompt: ?*data.Prompt = null,
history: *const client.HistoryPaletteState = &view.empty_history_palette,
suggestion: *const client.SuggestionState = &view.empty_suggestion,
path_completion: *const data.PathCompletionState = &view.empty_path_completion,
proxy_tls_active: bool = false,
proxy_tls_scope: core.ProxyScope = .exact,
proxy_system_trusted: bool = false,
system_metrics: ?client.SystemMetrics = null,
status_mode: client.Mode = .normal,
copy_mode_active: bool = false,
bar_state: *const client.State = &view.default_bars_state,
force: bool = false,
diagnostic: ?[]const u8 = null,
