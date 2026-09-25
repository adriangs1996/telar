const core = @import("telar-core");
const EditorOpenOperation = @import("EditorOpenOperation.zig");
const InitialOpen = @import("InitialOpen.zig");
const Split = @import("Split.zig");
const PaneOperation = @import("PaneOperation.zig");
const CreateTab = @import("CreateTab.zig");
const ChangeReviewOperation = @import("ChangeReviewOperation.zig");
const Group = @import("RequestsGroup.zig").RequestsGroup;

pub const RequestsContinuation = union(enum) {
    initial_open: InitialOpen,
    create_workspace: core.TerminalSize,
    rename_workspace: core.WorkspaceLocation,
    workspace_snapshot: core.WorkspaceLocation,
    tab_snapshot: core.TabLocation,
    split: Split,
    close_pane: PaneOperation,
    attach_pane: PaneOperation,
    create_tab: CreateTab,
    rename_tab: core.TabLocation,
    close_tab: core.TabLocation,
    move_tab: core.TabLocation,
    notification,
    change_review_query: ChangeReviewOperation,
    change_review_command: ChangeReviewOperation,
    editor_open: EditorOpenOperation,
    ignored,

    pub fn group(self: RequestsContinuation) Group {
        return switch (self) {
            .initial_open => .initial_open,
            .create_workspace, .rename_workspace => .workspace_operation,
            .workspace_snapshot => .workspace_snapshot,
            .tab_snapshot => .tab_snapshot,
            .split, .close_pane => .pane_operation,
            .attach_pane => .attachment,
            .create_tab, .rename_tab, .close_tab, .move_tab => .tab_operation,
            .notification => .notification,
            .change_review_query => .change_review_query,
            .change_review_command => .change_review_command,
            .editor_open => .editor_open,
            .ignored => .ignored,
        };
    }

    pub fn tabId(self: RequestsContinuation) ?core.TabId {
        return switch (self) {
            .change_review_query, .change_review_command => |operation| operation.location.tab_id,
            .editor_open => |operation| operation.location.tab_id,
            .tab_snapshot => |location| location.tab_id,
            .split => |split| split.location.tab_id,
            .close_pane, .attach_pane => |operation| operation.location.tab_id,
            .rename_tab, .close_tab, .move_tab => |location| location.tab_id,
            .initial_open, .create_workspace, .rename_workspace, .workspace_snapshot, .create_tab, .notification, .ignored => null,
        };
    }

    pub fn paneId(self: RequestsContinuation) ?core.PaneId {
        return switch (self) {
            .change_review_query, .change_review_command => |operation| operation.pane_id,
            .editor_open => |operation| operation.pane_id,
            .split => |split| split.target_pane,
            .close_pane, .attach_pane => |operation| operation.pane_id,
            .initial_open, .create_workspace, .rename_workspace, .workspace_snapshot, .tab_snapshot, .create_tab, .rename_tab, .close_tab, .move_tab, .notification, .ignored => null,
        };
    }
};
