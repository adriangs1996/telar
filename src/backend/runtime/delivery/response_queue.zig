//! Bounded, priority-aware responses awaiting one client session's writer.
const core = @import("telar-core");

const PendingFailure = @import("PendingFailure.zig");
const PendingTabCreated = @import("PendingTabCreated.zig");
const PendingTabRenamed = @import("PendingTabRenamed.zig");
const PendingNotification = @import("PendingNotification.zig");
const QueryResult = @import("../../history/QueryResult.zig");
const PathQuery = @import("../../paths/PathQuery.zig");
const PaneKey = @import("../../pane/PaneKey.zig");
const Matches = @import("Matches.zig");
const OutputResult = @import("../../history/OutputResult.zig");
const StatsResult = @import("../../history/StatsResult.zig");
const PendingSuggestion = @import("PendingSuggestion.zig");

/// Replies one session may hold. A reply that must not be lost (`push`)
/// answers a request of that same client, and a client keeps at most one
/// request per pane of the tab it shows plus a few singletons in flight
/// (`max_panes_per_tab + 8`, the client's request tracker), so the runtime's
/// pane total does not bound it. What reaches every client at once (closed
/// tabs, notifications) uses `pushOrDrop` or `pushNotification`, which fall
/// back to a resync or a counted drop instead of filling the queue.
pub const capacity = core.max_panes_per_tab * 2;

pub const PendingResponse = union(enum) {
    execution_reply: core.ExecutionReply,
    client_command: core.ClientCommand,
    client_command_result: core.ClientCommand,
    client_list: core.ClientList,
    editor_opened: core.EditorOpened,
    pane_opened: core.PaneOpened,
    worktree_registered: core.WorktreeRegistered,
    request_failed: PendingFailure,
    tab_snapshot: PendingTabSnapshot,
    workspace_snapshot: PendingWorkspaceSnapshot,
    tab_created: PendingTabCreated,
    tab_renamed: PendingTabRenamed,
    tab_closed: core.TabClosed,
    tab_moved: core.TabMoved,
    notification: PendingNotification,
    notification_shown: core.NotificationShown,
    agent_sound: core.AgentSoundNotification,
    history_result: *QueryResult,
    request_completed: core.RequestCompleted,
    pane_text: PendingPaneText,
    pane_matches: PendingPaneMatches,
    history_pruned: core.HistoryPruned,
    history_output: *OutputResult,
    history_stats: *StatsResult,
    pane_focus_command: core.PaneFocusCommand,
    pane_focus_result: core.PaneFocusResult,
    command_suggestion: PendingSuggestion,
    path_results: *PathQuery,
    /// Encoded from the runtime's limit registry when it is sent.
    limit_list: core.RequestId,
};

const PendingPaneMatches = struct {
    /// Search matches are small and computed at request time, so the reply owns
    /// its copy.
    request_id: core.RequestId,
    pane_id: core.PaneId,
    matches: Matches,
};

const PendingTabSnapshot = struct {
    request_id: core.RequestId,
    location: core.TabLocation,
};

const PendingPaneText = struct {
    /// Late-bound text read. The pane resolves at encode time so a queued read
    /// cannot borrow storage from a pane that exits before its send slot frees.
    request_id: core.RequestId,
    pane: PaneKey,
    rows: u16,
    source: core.PaneTextSource,
};

const PendingWorkspaceSnapshot = struct {
    request_id: core.RequestId,
    workspace: core.WorkspaceLocation,
};
