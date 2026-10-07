//! A client connects to a runtime again after losing it. The new session
//! starts as a fresh client would: every replica the lost session filled,
//! every graphics pause (they leave with the panes, in
//! `workspace_handoff.clear`) and every request it left unanswered is
//! dropped, while what the client owns itself (configuration, theme, host
//! facts, bars, notifications, timers and prompts it runs locally) stays. Revisions advance rather than
//! restart, so nothing cached by revision mistakes new state for old.
const ClientModel = @import("../state/ClientModel.zig");
const workspace_handoff = @import("../workspace/workspace_handoff.zig");

/// Forgets the lost session. The caller releases each pane's resources
/// first; this drops the pane records.
///
/// ```zig
/// runtime_session.forget(model);
/// ```
pub fn forget(model: *ClientModel) void {
    workspace_handoff.clear(model);
    model.startup = .{ .phase = .opening };
    model.request_lifecycle = .{};
    model.client_layouts = .{};
    model.navigation_history = .{};
    model.editor_open = .{};
    model.layout_snapshot = .{};
    model.layout_snapshot_tab = .invalid;
    model.saved_layouts = .{};
    model.name_prompt = .{};
    model.workspace_list_snapshot = .{};
    model.agent_snapshot = .{};
    model.acknowledged_agent = null;
    model.proxy_tls_active = false;
    model.proxy_tls_scope = .exact;
    model.proxy_system_trusted = false;
    model.system_metrics = null;
    model.cpu_history = .{};
    model.copy_state = null;
    model.selection_click_pane = null;
    model.selection_gesture = null;
    model.reported_pane_focus = null;
    model.pane_paste = null;
    model.to_runtime.discardQueued();

    advanceRevisions(model);
}

fn advanceRevisions(model: *ClientModel) void {
    inline for (.{
        "workspace_revision",
        "diagnostic_revision",
        "workspace_list_revision",
        "agent_revision",
        "proxy_status_revision",
        "system_metrics_revision",
        "tabs_revision",
        "active_tab_revision",
        "panes_revision",
        "frame_revision",
        "pane_metadata_revision",
        "pane_foreground_revision",
        "pane_progress_revision",
        "pane_graphics_revision",
        "chrome_revision",
        "copy_revision",
        "viewport_revision",
    }) |name| {
        @field(model, name) +%= 1;
    }
}
