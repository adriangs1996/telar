//! Value types and byte limits shared by every message family.
//!
//! Message envelopes live in `messages.zig`; this file holds the vocabulary
//! they are built from, so the codec layer can reference it without cycles.

const id = @import("id.zig");
const frame = @import("frame.zig");

pub const max_input_bytes = 64 * 1024;
pub const max_cwd_bytes = 4096;
pub const max_argument_count = 64;
pub const max_argument_bytes = 128 * 1024;
pub const max_environment_count = 256;
pub const max_environment_bytes = 512 * 1024;
pub const max_error_message_bytes = 1024;
pub const max_tab_label_bytes = 128;
pub const max_tabs_per_workspace = 64;
pub const max_panes_per_tab = 64;
pub const max_history_query_bytes = 1024;
pub const max_history_results = 100;
pub const max_history_command_bytes = 64 * 1024;

pub const TerminalSize = struct {
    cols: u16,
    rows: u16,
    /// Pixel size of one cell. Zero means the client has not learned it.
    cell_width_px: u16 = 0,
    cell_height_px: u16 = 0,

    pub fn validate(size: TerminalSize) !void {
        if (size.cols == 0 or size.rows == 0) return error.InvalidTerminalSize;
        const cells = @as(u32, size.cols) * @as(u32, size.rows);
        if (cells > frame.max_cell_count) return error.ScreenTooLarge;
    }
};

pub const PaneTarget = union(enum) {
    default,
    pane: id.PaneId,
};

/// A workspace-like container. Worktrees use the same tab model as their
/// source workspace, but remain independently addressable runtimes.
pub const WorkspaceLocation = union(enum) {
    workspace: id.WorkspaceId,
    worktree: id.WorktreeId,
};

/// Persistent identity of a tab and therefore of the pane layout it owns.
pub const TabLocation = struct {
    workspace: WorkspaceLocation,
    tab_id: id.TabId,
};

pub const EnvironmentMode = enum(u8) {
    inherit_runtime = 0,
    replace = 1,
};

pub const EnvironmentEntry = struct {
    name: []const u8,
    value: []const u8,
};

pub const Launch = struct {
    cwd: []const u8,
    arguments: []const []const u8,
    environment_mode: EnvironmentMode = .inherit_runtime,
    environment: []const EnvironmentEntry = &.{},
};

pub const TabMoveDirection = enum(u8) {
    previous = 0,
    next = 1,
};

pub const ExitKind = enum(u8) {
    exited = 0,
    signaled = 1,
};

pub const FailureCode = enum(u16) {
    pane_not_found = 1,
    invalid_request = 2,
    spawn_failed = 3,
    permission_denied = 4,
    resource_limit = 5,
    internal = 6,
    workspace_not_found = 7,
    tab_not_found = 8,
};

pub const PaneLifecycle = enum(u8) {
    running = 0,
    exited = 1,
};

pub const PaneDescriptor = struct {
    pane_id: id.PaneId,
    lifecycle: PaneLifecycle,
};

pub const TabDescriptor = struct {
    tab_id: id.TabId,
    position: u16,
    pane_count: u16,
    label: []const u8,
};

pub const HistoryScope = enum(u8) {
    global = 0,
    cwd = 1,
    workspace = 2,
    pane = 3,
};

pub const HistoryStatus = enum(u8) {
    completed = 0,
    interrupted = 1,
};

pub const HistoryEntry = struct {
    id: u64,
    pane_id: id.PaneId,
    started_at_ms: i64,
    duration_ns: i64,
    exit_code: ?i32,
    status: HistoryStatus,
    command: []const u8,
    cwd: []const u8,
    workspace_path: []const u8,
};
