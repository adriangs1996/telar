//! Frame-scoped widget dependencies and semantic UI actions.

const std = @import("std");
const core = @import("telar-core");
const theme = @import("../theme.zig");
const ui = @import("../ui.zig");
const sidebar_model = @import("sidebar_model.zig");

const schema = core.schema;

pub const Action = union(enum) {
    toggle_sidebar,
    focus_pane: schema.PaneId,
    select_tab: schema.TabId,
    active_workspace,
    active_worktree,
    sidebar_focus_search,
    sidebar_new_task,
    sidebar_command_palette,
    sidebar_select_tab: sidebar_model.Tab,
    sidebar_toggle_scope,
    sidebar_select_task: sidebar_model.TaskKey,
    sidebar_run_task_action: sidebar_model.TaskKey,
    sidebar_scroll_to: u16,
};

pub const Cursor = struct {
    cursor_x: u16,
    cursor_y: u16,
};

// Worst case is 64 visible task cards plus a one-row scrollbar target for
// every flattened row. The fixed table keeps the input path allocation-free.
pub const Hits = ui.Hits(Action, 576);

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
