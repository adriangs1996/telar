pub const Action = enum(u8) { workspace_select, tab_create, tab_select, tab_next, tab_previous, pane_create, pane_split, pane_close, pane_focus, pane_resize, pane_fullscreen };
pub const Status = enum(u8) { request, applied, admitted, failed };
