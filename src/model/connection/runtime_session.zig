//! A client connects to a runtime again after losing it. The new session
//! starts as a fresh client would: every replica the lost session filled,
//! every graphics pause (they leave with the panes, in
//! `workspace_handoff.clear`) and every request it left unanswered is
//! dropped, while what the client owns itself (configuration, theme, host
//! facts, bars, notifications, timers and prompts it runs locally) stays. Revisions advance rather than
//! restart, so nothing cached by revision mistakes new state for old.
const std = @import("std");
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
    model.change_review = .{};
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

test "forgetting a session drops runtime replicas and keeps client settings" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    try workspace_handoff.bootstrap(&model, .{
        .pane_id = @enumFromInt(3),
        .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(2) },
        .size = .{ .cols = 80, .rows = 24 },
    });
    model.startup.phase = .active;
    model.system_metrics = .{ .runtime_revision = 1, .cpu_percent = 10, .memory_used_decigib = 5, .battery_percent = null };
    model.sidebar_visible = false;
    const paused = model.graphics_pauses.add(@enumFromInt(3), 0);
    model.graphics_pauses.setWaiting(paused, true);
    const before = model.version();

    forget(&model);

    try std.testing.expectEqual(@as(usize, 0), model.tabs.count);
    try std.testing.expect(model.panes.find(@enumFromInt(3)) == null);
    try std.testing.expect(model.workspace == null);
    try std.testing.expect(model.startup.phase == .opening);
    try std.testing.expect(model.system_metrics == null);
    try std.testing.expectEqual(@as(usize, 0), model.graphics_pauses.count);
    try std.testing.expectEqual(@as(usize, 0), model.graphics_pauses.waiting_count);
    try std.testing.expect(!model.sidebar_visible);
    try std.testing.expect(model.version().tabs > before.tabs);
    try std.testing.expect(model.version().frame > before.frame);
}
