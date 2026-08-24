//! Frame-scoped widget dependencies and semantic UI actions.

const std = @import("std");
const core = @import("telar-core");
const theme = @import("../theme.zig");
const ui = @import("../ui.zig");

const schema = core.schema;

pub const Action = union(enum) {
    toggle_sidebar,
    focus_pane: schema.PaneId,
    select_tab: schema.TabId,
    active_workspace,
    active_worktree,
};

pub const Hits = ui.Hits(Action, 128);

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
