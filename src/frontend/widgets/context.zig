//! Frame-scoped widget dependencies and semantic UI actions.

const std = @import("std");
const core = @import("telar-core");
const ui = @import("../ui/root.zig");
const theme = ui.theme;
const notification = @import("notification.zig");
const sidebar_model = @import("sidebar_model.zig");

const schema = core.schema;

pub const Action = union(enum) {
    toggle_sidebar,
    focus_pane: schema.PaneId,
    select_tab: schema.TabId,
    active_workspace,
    select_workspace: schema.WorkspaceId,
    toggle_workspace_list,
    sidebar_select_agent: sidebar_model.AgentKey,
    sidebar_scroll_to: u16,
    notification_activate: notification.Id,
    notification_dismiss: notification.Id,
};

pub const Cursor = struct {
    cursor_x: u16,
    cursor_y: u16,
};

// Worst case is 64 visible agent cards plus a one-row scrollbar target for
// every flattened row, one segment per open workspace in the top bar and two
// targets for each visible notification.
// The fixed table keeps the input path allocation-free.
pub const Hits = ui.Hits(Action, 704);

/// Widgets receive no client state and cannot mutate navigation, layout,
/// transport, or runtime models.
pub const Context = struct {
    buffer: *ui.Buffer,
    hits: *Hits,
    palette: *const theme.Palette,
    hovered: ?Action,

    pub fn isHovered(context: *const Context, action: Action) bool {
        const hovered = context.hovered orelse return false;
        return std.meta.eql(hovered, action);
    }
};
