//! Shared client operations grouped by behavior. Process event switches call
//! these functions with concrete client state; host services keep their ports.

pub const ClipboardImageCompletion = @import("host/Completion.zig");
pub const agent_navigation = @import("agents/agent_navigation.zig");
pub const attachment_prompts = @import("input/attachment_prompts.zig");
pub const bar_updates = @import("configuration/bar_updates.zig");
pub const client_detachments = @import("session/client_detachments.zig");
pub const clipboard_images = @import("host/clipboard_images.zig");
pub const config_reloads = @import("configuration/config_reloads.zig");
pub const copy_mode_pointer = @import("input/copy_mode_pointer.zig");
pub const favicons = @import("workspaces/favicons.zig");
pub const key_routing = @import("input/key_routing.zig");
pub const lua_actions = @import("configuration/lua_actions.zig");
pub const name_prompts = @import("input/name_prompts.zig");
pub const pane_focus_reports = @import("panes/pane_focus_reports.zig");
pub const pane_graphics = @import("panes/pane_graphics.zig");
pub const pane_inputs = @import("input/pane_inputs.zig");
pub const pane_mouse_inputs = @import("input/pane_mouse_inputs.zig");
pub const pane_pastes = @import("input/pane_pastes.zig");
pub const pane_viewports = @import("panes/pane_viewports.zig");
pub const paste_routing = @import("input/paste_routing.zig");
pub const path_completions = @import("input/path_completions.zig");
pub const plugin_actions = @import("configuration/plugin_actions.zig");
pub const pointer_routing = @import("input/pointer_routing.zig");
pub const sidebar_projection = @import("notifications/sidebar_projection.zig");
pub const sidebar_toggles = @import("notifications/sidebar_toggles.zig");
pub const tab_selections = @import("tabs/tab_selections.zig");
pub const view_interactions = @import("input/view_interactions.zig");
pub const workspace_renames = @import("workspaces/workspace_renames.zig");
