const core = @import("telar-core");

pub const NotificationTarget = union(enum) {
    none,
    focus_pane: core.PaneId,
    select_tab: core.TabId,
    select_workspace: core.WorkspaceId,
};
