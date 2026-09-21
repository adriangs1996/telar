//! Routes decoded runtime messages to concrete client operations.
//! State transitions, resource delivery and correlation stay in those operations.
//! This dispatcher only maps their control outcomes to the client loop.
pub const link_openings = @import("../operations/input/link_openings.zig");

const Client = @import("../AttachedClient.zig");
const ServerMessageType = @import("telar-core").ServerMessage;

pub const change_review = @import("../operations/change_review/change_review.zig");
pub const agent_sounds = @import("../operations/agents/agent_sounds.zig");
pub const agent_snapshots = @import("../operations/agents/agent_snapshots.zig");
pub const agent_history = @import("../operations/agents/agent_history.zig");
pub const agent_threads = @import("../operations/agents/agent_threads.zig");
pub const notifications = @import("../operations/notifications/notifications.zig");
pub const client_layouts = @import("../operations/session/client_layouts.zig");
pub const pane_clipboards = @import("../operations/panes/pane_clipboards.zig");
pub const pane_closures = @import("../operations/panes/pane_closures.zig");
pub const pane_frames = @import("../operations/panes/pane_frames.zig");
pub const client_commands = @import("../operations/session/client_commands.zig");
pub const pane_focus_commands = @import("../operations/panes/pane_focus_commands.zig");
pub const pane_graphics = @import("../operations/panes/pane_graphics.zig");
pub const pane_metadata = @import("../operations/panes/pane_metadata.zig");
pub const pane_openings = @import("../operations/panes/pane_openings.zig");
pub const pane_progress = @import("../operations/panes/pane_progress.zig");
pub const copy_modes = @import("../operations/input/copy_modes.zig");
pub const history_palettes = @import("../operations/input/history_palettes.zig");
pub const suggestions = @import("../operations/input/suggestions.zig");
pub const proxy_status = @import("../operations/agents/proxy_status.zig");
pub const request_failures = @import("../operations/session/request_failures.zig");
pub const resync_requirements = @import("../operations/session/resync_requirements.zig");
pub const system_metrics = @import("../operations/agents/system_metrics.zig");
pub const tab_closures = @import("../operations/tabs/tab_closures.zig");
pub const tab_creations = @import("../operations/tabs/tab_creations.zig");
pub const tab_moves = @import("../operations/tabs/tab_moves.zig");
pub const tab_renames = @import("../operations/tabs/tab_renames.zig");
pub const tab_snapshots = @import("../operations/tabs/tab_snapshots.zig");
pub const workspace_lists = @import("../operations/workspaces/workspace_lists.zig");
pub const workspace_snapshots = @import("../operations/workspaces/workspace_snapshots.zig");

/// Dispatches one borrowed runtime reply to its concrete operation.
/// Example: `const status = try handleServerMessage(client, message);`
pub fn handleServerMessage(client: *Client, message: ServerMessageType) !?u8 {
    switch (message) {
        .change_review_changed => |notification| {
            _ = change_review.changed(client, notification);
        },
        .change_review_snapshot => |snapshot| {
            _ = try change_review.apply(client, snapshot);
        },
        .editor_opened => |reply| {
            try link_openings.editorOpened(client, reply);
        },
        .agent_history_page => |page| {
            _ = try agent_history.apply(client, page);
        },
        .agent_thread_snapshot => |snapshot| {
            _ = try agent_threads.apply(client, snapshot);
        },
        .request_completed => |reply| {
            try agent_threads.completed(client, reply);
        },
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
        .pane_progress => |progress| _ = try pane_progress.apply(client, progress),
        .client_command => |command| try client_commands.apply(client, command),
        .pane_focus_command => |command| try pane_focus_commands.apply(client, command),
        .pane_matches => |found| _ = try copy_modes.matches(client, found),
        .pane_clipboard => |clipboard| try pane_clipboards.apply(client, clipboard),
        .pane_exited => |exited| _ = try pane_closures.applyExit(client, exited),
        .request_failed => |failure| {
            if (!history_palettes.failed(client, failure)) {
                _ = try request_failures.apply(client, failure);
            }
        },
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
        .history_results => |results| _ = try history_palettes.apply(client, results),
        .history_pruned => |confirmation| _ = try history_palettes.pruned(client, confirmation),
        .history_output => |output| _ = history_palettes.output(client, output),
        .command_suggestion => |suggested| _ = try suggestions.apply(client, suggested),
        .client_command_result, .client_list, .pane_text, .history_stats_result, .pane_focus_result => return error.UnexpectedControlReply,
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
