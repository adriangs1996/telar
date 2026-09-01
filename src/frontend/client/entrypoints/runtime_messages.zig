//! Routes decoded runtime messages to client slice adapters.
//! State transitions, resource effects and correlation stay in those adapters.
//! This dispatcher only maps their control outcomes to the client loop.

const core = @import("telar-core");

const schema = core.schema;

const Client = @import("../client.zig");
const agent_sounds = @import("../controllers/agents/agent_sounds.zig");
const agent_snapshots = @import("../controllers/agents/agent_snapshots.zig");
const notifications = @import("../controllers/notifications/notifications.zig");
const client_layouts = @import("../controllers/session/client_layouts.zig");
const pane_clipboards = @import("../controllers/panes/pane_clipboards.zig");
const pane_closures = @import("../controllers/panes/pane_closures.zig");
const pane_frames = @import("../controllers/panes/pane_frames.zig");
const pane_graphics = @import("../controllers/panes/pane_graphics.zig");
const pane_metadata = @import("../controllers/panes/pane_metadata.zig");
const pane_openings = @import("../controllers/panes/pane_openings.zig");
const proxy_status = @import("../controllers/agents/proxy_status.zig");
const request_failures = @import("../controllers/session/request_failures.zig");
const resync_requirements = @import("../controllers/session/resync_requirements.zig");
const system_metrics = @import("../controllers/agents/system_metrics.zig");
const tab_closures = @import("../controllers/tabs/tab_closures.zig");
const tab_creations = @import("../controllers/tabs/tab_creations.zig");
const tab_moves = @import("../controllers/tabs/tab_moves.zig");
const tab_renames = @import("../controllers/tabs/tab_renames.zig");
const tab_snapshots = @import("../controllers/tabs/tab_snapshots.zig");
const workspace_lists = @import("../controllers/workspaces/workspace_lists.zig");
const workspace_snapshots = @import("../controllers/workspaces/workspace_snapshots.zig");

/// Routes one decoded message from the runtime.
pub fn handleServerMessage(client: *Client, message: schema.ServerMessage) !?u8 {
    switch (message) {
        .pane_opened => |opened| _ = try pane_openings.apply(client, opened),
        .tab_snapshot => |snapshot| _ = try tab_snapshots.apply(client, snapshot),
        .workspace_snapshot => |snapshot| try workspace_snapshots.apply(client, snapshot),
        .tab_created => |created| _ = try tab_creations.apply(client, created),
        .tab_renamed => |renamed| _ = try tab_renames.apply(client, renamed),
        .tab_closed => |closed| switch (try tab_closures.apply(client, closed)) {
            .applied, .ignored => {},
            .exit => return 0,
        },
        .tab_moved => |moved| _ = try tab_moves.apply(client, moved),
        .pane_frame => |frame| _ = try pane_frames.apply(client, frame),
        .pane_cwd => |cwd| _ = try pane_metadata.applyCwd(client, cwd),
        .pane_foreground => |foreground| _ = try pane_metadata.applyForeground(client, foreground),
        .pane_title => |title| _ = try pane_metadata.applyTitle(client, title),
        .pane_clipboard => |clipboard| try pane_clipboards.apply(client, clipboard),
        .pane_exited => |exited| _ = try pane_closures.applyExit(client, exited),
        .request_failed => |failure| _ = try request_failures.apply(client, failure),
        .notification => |notification| _ = try notifications.applyRuntime(client, notification),
        .notification_shown => |shown| _ = try notifications.applyDeliveryReport(client, shown),
        .agent_sound => |sound| _ = try agent_sounds.apply(client, sound),
        .client_layout_snapshot => |snapshot| try client_layouts.apply(client, snapshot),
        .resync_required => |required| {
            if (try resync_requirements.apply(client, required) == .exit) {
                return 0;
            }
        },
        .runtime_stopping => return 0,
        .history_results => return error.UnexpectedHistoryResults,
        .pane_text, .request_completed => return error.UnexpectedControlReply,
        .proxy_status => |status| _ = try proxy_status.apply(client, status),
        .agent_snapshot => |snapshot| _ = try agent_snapshots.apply(client, snapshot),
        .system_metrics => |metrics| _ = try system_metrics.apply(client, metrics),
        .workspace_list => |list| _ = try workspace_lists.apply(client, list),
        .graphics_snapshot => |snapshot| _ = try pane_graphics.apply(client, .{ .snapshot = snapshot }),
        .graphics_image => |image| _ = try pane_graphics.apply(client, .{ .image = image }),
        .graphics_shared_image => |image| _ = try pane_graphics.apply(client, .{ .shared_image = image }),
        .graphics_image_chunk => |chunk| _ = try pane_graphics.apply(client, .{ .image_chunk = chunk }),
        .graphics_placement => |placement| _ = try pane_graphics.apply(client, .{ .placement = placement }),
        .graphics_delete_image => |deleted| _ = try pane_graphics.apply(client, .{ .delete_image = deleted }),
        .graphics_delete_placement => |deleted| _ = try pane_graphics.apply(client, .{ .delete_placement = deleted }),
    }
    return null;
}
