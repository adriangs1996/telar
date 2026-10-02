//! Application policy for dispatching one semantic view interaction.
const core = @import("telar-core");
const model_data = @import("model");
const MachineAgent = @import("../machines/MachineAgent.zig");
const MachineWorktree = @import("../machines/MachineWorktree.zig");
const TabMoveIntent = @import("../workspace/TabMoveIntent.zig");

pub const Intent = union(enum) {
    none,
    toggle_sidebar,
    resize_sidebar: u16,
    toggle_workspace_list,
    focus_agent: model_data.AgentKey,
    /// A secondary press on an agent card: peek at it without leaving the tab.
    peek_agent: model_data.AgentKey,
    select_tab: core.TabId,
    move_tab: TabMoveIntent,
    focus_pane: core.PaneId,
    rename_tab: core.TabId,
    /// The strip's `+` control: the same request the `create_tab` action sends.
    create_tab,
    /// The fullscreen band's leave control: the same toggle the
    /// `toggle_pane_fullscreen` action performs.
    toggle_pane_fullscreen,
    select_workspace: core.WorkspaceId,
    notification_activate: model_data.NotificationId,
    notification_dismiss: model_data.NotificationId,
    attachment_dismiss: model_data.AttachmentId,
    /// The status bar's diagnostic chip: clears the client diagnostic.
    diagnostic_dismiss,
    /// A pointer press on one visible row of the active list prompt.
    prompt_row: u16,
    palette_mode: model_data.CommandPalettePrefix,
    /// A click on a configured bar component with an action or a url.
    bar_component: model_data.BarComponent,
    /// A click on a button of the open panel, by its index in the panel.
    panel_component: u8,
    /// The `+N` chip of a bar too narrow for its components.
    toggle_bar_overflow,
    /// The panel's close control, or a press outside the open panel.
    close_panel,
    /// The top bar's machine segment: the palette on the window's machines.
    machine_picker,
    /// One machine of the sidebar's switcher, by its slot.
    select_machine: u8,
    focus_machine_agent: MachineAgent,
    peek_machine_agent: MachineAgent,
    open_machine_worktree: MachineWorktree,
};

/// What a secondary (right) press on a target does: rename a tab, peek at an
/// agent, nothing elsewhere.
///
/// ```zig
/// const intent = view_interaction.secondary(.{ .focus_agent = key });
/// ```
pub fn secondary(intent: Intent) Intent {
    return switch (intent) {
        .select_tab => |tab_id| .{ .rename_tab = tab_id },
        .focus_agent => |key| .{ .peek_agent = key },
        .focus_machine_agent => |target| .{ .peek_machine_agent = target },
        else => .none,
    };
}

pub fn capturesPaneInput(intent: Intent) bool {
    return switch (intent) {
        .select_tab, .focus_agent, .peek_agent, .focus_machine_agent, .peek_machine_agent, .open_machine_worktree => true,
        else => false,
    };
}
