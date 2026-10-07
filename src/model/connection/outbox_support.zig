//! Bounded, allocation-free queue for messages sent by one frontend client.
//!
//! Variable input, creation labels, rename, notification, and launch-cwd bytes are copied
//! because their producers may reuse or replace their buffers as soon as the
//! event handler returns. One encoded buffer is borrowed only while a send
//! actor is active.
const data = @import("../model.zig");

const OwnedInput = @import("OwnedInput.zig");
const OwnedCreatePane = @import("OwnedCreatePane.zig");
const OwnedCreateTab = @import("OwnedCreateTab.zig");
const OwnedRename = @import("OwnedRename.zig");
const OwnedCreateWorkspace = @import("OwnedCreateWorkspace.zig");
const OwnedWorkspaceRename = @import("OwnedWorkspaceRename.zig");
const core = @import("telar-core");

pub const capacity = core.max_panes_per_tab + 16;

/// Request groups permit at most one pane launch, one tab launch, and one
/// workspace launch at once. Keep one spare for bootstrap or recovery.
pub const max_pending_launches = 4;

pub const Message = union(enum) {
    open_editor: core.OpenEditor,
    open_pane: core.OpenPane,
    pane_input: OwnedInput,
    pane_resize: core.PaneResize,
    frame_ack: core.FrameAck,
    request_snapshot: core.RequestSnapshot,
    detach_pane: core.DetachPane,
    request_tab_snapshot: core.RequestTabSnapshot,
    create_pane: OwnedCreatePane,
    close_pane: core.ClosePane,
    request_workspace_snapshot: core.RequestWorkspaceSnapshot,
    create_tab: OwnedCreateTab,
    rename_tab: OwnedRename,
    close_tab: core.CloseTab,
    move_tab: core.MoveTab,
    request_graphics_snapshot: core.RequestGraphicsSnapshot,
    graphics_credit: core.GraphicsCredit,
    configure_graphics: core.ConfigureGraphics,
    configure_terminal_colors: core.TerminalColors,
    configure_frame_interval: core.ConfigureFrameInterval,
    request_runtime_state: core.RequestRuntimeState,
    create_workspace: OwnedCreateWorkspace,
    rename_workspace: OwnedWorkspaceRename,
    set_pane_viewport: core.SetPaneViewport,
    copy_selection: core.CopySelection,
    /// Encoded `show_notification` length in the slot's payload.
    show_notification: u16,
    client_layout: u8,
    acknowledge_agent: core.AcknowledgeAgent,
    search_pane: data.OwnedSearch,
    query_history: data.OwnedHistoryQuery,
    delete_history: core.DeleteHistory,
    read_history_output: core.ReadHistoryOutput,
    complete_client_command: u16,
    /// Encoded `find_paths` length in the slot's payload.
    find_paths: u16,
    complete_pane_focus: core.CompletePaneFocus,
    /// A control request the client encoded itself into the item's payload:
    /// peek reads, prompts, interrupts and worktree launches.
    encoded: u16,
};

pub fn messageLaunchCwd(message: Message) ?[]const u8 {
    return switch (message) {
        .open_pane => |value| if (value.launch) |launch| launch.cwd else null,
        .create_pane => |value| value.launch.cwd,
        .create_tab => |value| value.launch.cwd,
        .create_workspace => |value| value.launch.cwd,
        else => null,
    };
}
