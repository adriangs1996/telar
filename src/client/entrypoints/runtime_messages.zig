//! Dispatch policy shared by host drivers. Slice adapters perform delivery.

const ServerMessageType = @import("telar-core").ServerMessage;

/// Dispatches borrowed decoded input synchronously. Adapters must own deferred data.
/// Example: `const exit_code = try dispatch(client, message, Adapters);`.
pub fn dispatch(client: anytype, message: ServerMessageType, comptime Adapters: type) !?u8 {
    const agent_sounds = Adapters.agent_sounds;
    const agent_snapshots = Adapters.agent_snapshots;
    const notifications = Adapters.notifications;
    const client_layouts = Adapters.client_layouts;
    const pane_clipboards = Adapters.pane_clipboards;
    const pane_closures = Adapters.pane_closures;
    const pane_frames = Adapters.pane_frames;
    const pane_focus_commands = Adapters.pane_focus_commands;
    const pane_graphics = Adapters.pane_graphics;
    const pane_metadata = Adapters.pane_metadata;
    const pane_openings = Adapters.pane_openings;
    const pane_progress = Adapters.pane_progress;
    const copy_modes = Adapters.copy_modes;
    const history_palettes = Adapters.history_palettes;
    const suggestions = Adapters.suggestions;
    const proxy_status = Adapters.proxy_status;
    const request_failures = Adapters.request_failures;
    const resync_requirements = Adapters.resync_requirements;
    const system_metrics = Adapters.system_metrics;
    const tab_closures = Adapters.tab_closures;
    const tab_creations = Adapters.tab_creations;
    const tab_moves = Adapters.tab_moves;
    const tab_renames = Adapters.tab_renames;
    const tab_snapshots = Adapters.tab_snapshots;
    const workspace_lists = Adapters.workspace_lists;
    const workspace_snapshots = Adapters.workspace_snapshots;

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
        .pane_progress => |progress| _ = try pane_progress.apply(client, progress),
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
        .pane_text, .request_completed, .history_stats_result, .pane_focus_result => return error.UnexpectedControlReply,
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
