//! Application policy for dispatching one semantic view interaction.
const core = @import("telar-core");
const model_data = @import("model");

pub const Intent = union(enum) {
    none,
    toggle_sidebar,
    resize_sidebar: u16,
    toggle_workspace_list,
    focus_agent: model_data.AgentKey,
    select_tab: core.TabId,
    move_tab: @import("../tabs/TabMoveIntent.zig"),
    focus_pane: core.PaneId,
    rename_tab: core.TabId,
    /// The strip's `+` control: the same request the `create_tab` action sends.
    create_tab,
    select_workspace: core.WorkspaceId,
    notification_activate: model_data.NotificationId,
    notification_dismiss: model_data.NotificationId,
    attachment_dismiss: model_data.AttachmentId,
    /// A pointer press on one visible row of the active list prompt.
    prompt_row: u16,
};

pub fn capturesPaneInput(intent: Intent) bool {
    return switch (intent) {
        .select_tab, .focus_agent => true,
        else => false,
    };
}

pub const Event = union(enum) {
    intent: Intent,
    invalidate_graphics_placements,
    offer_pane_geometry,
};

pub const Failure = enum {
    none,
    intent,
    pane_geometry,
};
