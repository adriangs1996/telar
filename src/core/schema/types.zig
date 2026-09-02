//! Value types and byte limits shared by every message family.
//!
//! Message envelopes live in `messages.zig`; this file holds the vocabulary
//! they are built from, so the codec layer can reference it without cycles.

const id = @import("id.zig");
const frame = @import("frame.zig");

pub const max_input_bytes = 64 * 1024;
pub const max_cwd_bytes = 4096;
pub const max_workspace_name_bytes = max_cwd_bytes;
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
pub const max_agent_snapshot_entries = max_panes_per_tab;
pub const max_agent_workspace_label_bytes = 48;
pub const max_agent_session_title_bytes = 96;
pub const max_agent_cwd_label_bytes = 48;
pub const max_foreground_name_bytes = 48;
pub const max_pane_title_bytes = 256;
pub const max_workspace_list_entries = 64;
pub const max_git_branch_bytes = 64;
pub const max_search_needle_bytes = 128;
pub const max_search_matches = 64;
pub const max_pane_text_rows = 200;
pub const max_pane_text_bytes = 64 * 1024;
pub const max_pane_text_input_bytes = 16 * 1024;
pub const max_notification_title_bytes = 48;
pub const max_notification_message_bytes = 192;
pub const max_client_layout_clients = 8;
pub const max_client_layout_tabs = max_panes_per_tab;
pub const max_client_layout_nodes = max_panes_per_tab * 2 - 1;
pub const max_client_layout_wire_bytes = 4096;
pub const client_layout_ratio_scale: u16 = 10_000;
pub const min_client_layout_ratio: u16 = client_layout_ratio_scale / 10;
pub const max_client_layout_ratio: u16 = client_layout_ratio_scale - min_client_layout_ratio;
pub const min_notification_duration_ms: u32 = 500;
pub const max_notification_duration_ms: u32 = 60_000;
pub const default_notification_duration_ms: u32 = 4_000;

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
    workspace: id.WorkspaceId,
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
    /// When present, the runtime resolves the launch cwd from this attached
    /// pane. `cwd` remains the explicit launch path for callers that do not
    /// request inheritance.
    cwd_source: ?id.PaneId = null,
    arguments: []const []const u8,
    environment_mode: EnvironmentMode = .inherit_runtime,
    environment: []const EnvironmentEntry = &.{},
};

pub const TabMoveDirection = enum(u8) {
    previous = 0,
    next = 1,
};

pub const PaneDirection = enum(u8) {
    left = 0,
    right = 1,
    up = 2,
    down = 3,
};

pub const PaneFocusOutcome = enum(u8) {
    focused = 0,
    no_neighbor = 1,
    source_not_focused = 2,
};

pub const ClientIdentity = enum(u64) {
    invalid = 0,
    _,
};

pub const ClientLayoutAxis = enum(u8) {
    horizontal = 0,
    vertical = 1,
};

pub const ClientLayoutSplit = struct {
    axis: ClientLayoutAxis,
    ratio: u16,
};

/// One node in a pre-order binary pane-layout tree. Split children immediately
/// follow their parent, so the wire never carries disposable client indices.
pub const ClientLayoutNode = union(enum) {
    pane: id.PaneId,
    split: ClientLayoutSplit,
};

pub const ClientTabLayout = struct {
    location: TabLocation,
    focused_pane: id.PaneId,
    fullscreen: bool,
    workspace_active: bool = false,
    nodes: []const ClientLayoutNode,
};

pub const ClientLayoutUpdate = struct {
    sidebar_visible: bool,
    sidebar_width: u16,
    workspace_list_collapsed: bool,
    active_tab: TabLocation,
    tabs: []const ClientTabLayout,
};

pub const ClientLayoutSnapshot = struct {
    restored: bool,
    sidebar_visible: bool = true,
    sidebar_width: u16 = 0,
    workspace_list_collapsed: bool = false,
    active_tab: ?TabLocation = null,
    tabs: []const ClientTabLayout = &.{},
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
    agent_blocked = 9,
    pane_exited = 10,
};

/// Rows a text read covers: the visible screen, or the most recent rows of
/// scrollback plus screen.
pub const PaneTextSource = enum(u8) {
    screen = 0,
    recent = 1,
};

/// One text match in absolute scrollback coordinates.
pub const SearchMatch = struct {
    x: u16,
    y: u32,
    len: u16,
};

/// How text sent to a pane is delivered. `prompt` wraps it in bracketed paste
/// when the child enabled that mode, appends Enter, and is refused while the
/// agent is blocked.
pub const PaneTextMode = enum(u8) {
    raw = 0,
    prompt = 1,
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

/// Who submitted a recorded command: a person typing, or automation writing
/// into the pane through the control API or a session restore.
pub const HistoryAuthor = enum(u8) {
    human = 0,
    agent = 1,
};

pub const HistoryAuthorFilter = enum(u8) {
    all = 0,
    human = 1,
    agent = 2,
};

pub const NotificationLevel = enum(u8) {
    info = 0,
    success = 1,
    warning = 2,
    failure = 3,
};

/// A notification click resolves to current client state. IDs may become
/// stale between publication and activation; clients ignore stale targets.
pub const NotificationTarget = union(enum) {
    none,
    pane: id.PaneId,
    tab: id.TabId,
    workspace: id.WorkspaceId,
};

pub const HistoryEntry = struct {
    id: u64,
    pane_id: id.PaneId,
    started_at_ms: i64,
    duration_ns: i64,
    exit_code: ?i32,
    status: HistoryStatus,
    author: HistoryAuthor = .human,
    command: []const u8,
    cwd: []const u8,
    workspace_path: []const u8,
};

/// Agent vocabulary published by the runtime. These values describe evidence,
/// not authority to act on behalf of an agent.
/// Agent identity. Built-in providers have names here; indexes from
/// `first_custom_agent_provider` are assigned by the agent manifest table in
/// configuration order, and `AgentSnapshotEntry.provider_name` carries the
/// display name so clients never need the table.
pub const AgentProvider = enum(u8) {
    unknown = 0,
    claude = 1,
    codex = 2,
    _,
};

pub const max_agent_manifests = 16;
pub const first_custom_agent_provider: u8 = 3;
pub const max_agent_provider_index: u8 = first_custom_agent_provider + max_agent_manifests - 1;
pub const max_agent_provider_name_bytes = 32;
/// Bound for an agent's own session reference as reported by its hooks.
pub const max_agent_session_reference_bytes = 64;

pub const AgentStatus = enum(u8) {
    unknown = 0,
    working = 1,
    blocked = 2,
    ready = 3,
    failed = 4,
    /// Finished a turn while no client had the pane focused. Clears back to
    /// `ready` once a client acknowledges the agent.
    done = 5,
};

/// Audible client-side effects produced by exact runtime-owned agent
/// transitions. The pane generation prevents a delayed effect from being
/// attributed to a reused pane ID.
pub const AgentSound = enum(u8) {
    ready = 0,
    needs_input = 1,
};

pub const AgentSoundNotification = struct {
    pane_id: id.PaneId,
    pane_generation: u64,
    sound: AgentSound,
};

pub const AgentSource = enum(u8) {
    proxy_tls = 0,
    screen = 1,
    foreground_process = 2,
    /// An official lifecycle report from the agent's own hooks.
    lifecycle_report = 3,
};

/// State an agent reports about itself through its lifecycle hooks.
pub const AgentReportState = enum(u8) {
    working = 0,
    blocked = 1,
    ready = 2,
    exited = 3,
};

pub const AgentAuthority = enum(u8) {
    candidate = 0,
    active = 1,
    obscured = 2,
    resumed = 3,
    exited = 4,
    stale = 5,
};

pub const AgentTitleSource = enum(u8) {
    telar = 0,
    generated = 1,
    manual = 2,
    /// The child's own OSC 0/2 window title, shown until a generated or
    /// manual title exists.
    terminal = 3,
};

pub const AgentTitleState = enum(u8) {
    placeholder = 0,
    pending = 1,
    ready = 2,
    failed = 3,
};

pub const AgentSnapshotEntry = struct {
    pane_id: id.PaneId,
    pane_generation: u64,
    location: TabLocation = .{
        .workspace = .{ .workspace = .invalid },
        .tab_id = .invalid,
    },
    /// One-based position among the currently open panes in this tab.
    pane_index: u16 = 0,
    process_id: u32,
    session_id: [16]u8,
    workspace_label: []const u8 = "",
    tab_label: []const u8 = "",
    session_title: []const u8 = "",
    title_source: AgentTitleSource = .telar,
    title_state: AgentTitleState = .placeholder,
    cwd_label: []const u8 = "",
    provider: AgentProvider,
    /// Display name for `provider`; empty only for `unknown`.
    provider_name: []const u8 = "",
    status: AgentStatus,
    source: AgentSource,
    authority: AgentAuthority,
    confidence: u8,
    sequence: u64,
    observed_at_ms: i64,
    expires_at_ms: i64,
};
