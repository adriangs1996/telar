//! Application policy for dispatching one semantic view interaction.

const AgentKeyType = @import("../../agents/AgentKey.zig");
const TabIdType = @import("telar-core").TabId;
const PaneIdType = @import("telar-core").PaneId;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const notification_capability = @import("../../notifications/notifications.zig");
const types = @import("../../attachments/types.zig");
const std = @import("std");
const ViewInteractionOutcome = @import("ViewInteractionOutcome.zig");
const ViewInteractionCommand = @import("ViewInteractionCommand.zig");

pub const Intent = union(enum) {
    none,
    toggle_sidebar,
    resize_sidebar: u16,
    toggle_workspace_list,
    focus_agent: AgentKeyType,
    select_tab: TabIdType,
    move_tab: @import("../tabs/TabMoveIntent.zig"),
    focus_pane: PaneIdType,
    rename_tab: TabIdType,
    /// The strip's `+` control: the same request the `create_tab` action sends.
    create_tab,
    select_workspace: WorkspaceIdType,
    notification_activate: notification_capability.Id,
    notification_dismiss: notification_capability.Id,
    attachment_dismiss: types.Id,
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
