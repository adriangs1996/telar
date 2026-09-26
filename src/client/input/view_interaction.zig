//! Application policy for dispatching one semantic view interaction.
const core = @import("telar-core");
const model_data = @import("model");
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
    /// A pointer press on one visible row of the active list prompt.
    prompt_row: u16,
};

pub fn capturesPaneInput(intent: Intent) bool {
    return switch (intent) {
        .select_tab, .focus_agent, .peek_agent => true,
        else => false,
    };
}
