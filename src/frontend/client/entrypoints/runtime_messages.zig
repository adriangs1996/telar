//! Routes decoded runtime messages to client slice adapters.
//! State transitions, resource effects and correlation stay in those adapters.
//! This dispatcher only maps their control outcomes to the client loop.

const Client = @import("../Client.zig");
const ServerMessageType = @import("telar-core").ServerMessage;
const dispatch_module = @import("telar-client").dispatch;

pub const agent_sounds = @import("../controllers/agents/agent_sounds.zig");
pub const agent_snapshots = @import("../controllers/agents/agent_snapshots.zig");
pub const notifications = @import("../controllers/notifications/notifications.zig");
pub const client_layouts = @import("../controllers/session/client_layouts.zig");
pub const pane_clipboards = @import("../controllers/panes/pane_clipboards.zig");
pub const pane_closures = @import("../controllers/panes/pane_closures.zig");
pub const pane_frames = @import("../controllers/panes/pane_frames.zig");
pub const pane_focus_commands = @import("../controllers/panes/pane_focus_commands.zig");
pub const pane_graphics = @import("../controllers/panes/pane_graphics.zig");
pub const pane_metadata = @import("../controllers/panes/pane_metadata.zig");
pub const pane_openings = @import("../controllers/panes/pane_openings.zig");
pub const pane_progress = @import("../controllers/panes/pane_progress.zig");
pub const copy_modes = @import("../controllers/input/copy_modes.zig");
pub const history_palettes = @import("../controllers/input/history_palettes.zig");
pub const suggestions = @import("../controllers/input/suggestions.zig");
pub const proxy_status = @import("../controllers/agents/proxy_status.zig");
pub const request_failures = @import("../controllers/session/request_failures.zig");
pub const resync_requirements = @import("../controllers/session/resync_requirements.zig");
pub const system_metrics = @import("../controllers/agents/system_metrics.zig");
pub const tab_closures = @import("../controllers/tabs/tab_closures.zig");
pub const tab_creations = @import("../controllers/tabs/tab_creations.zig");
pub const tab_moves = @import("../controllers/tabs/tab_moves.zig");
pub const tab_renames = @import("../controllers/tabs/tab_renames.zig");
pub const tab_snapshots = @import("../controllers/tabs/tab_snapshots.zig");
pub const workspace_lists = @import("../controllers/workspaces/workspace_lists.zig");
pub const workspace_snapshots = @import("../controllers/workspaces/workspace_snapshots.zig");

/// Routes one decoded message from the runtime.
pub fn handleServerMessage(client: *Client, message: ServerMessageType) !?u8 {
    return dispatch_module(client, message, @This());
}
