pub const RequestsGroup = enum {
    initial_open,
    workspace_operation,
    workspace_snapshot,
    tab_snapshot,
    pane_operation,
    attachment,
    tab_operation,
    notification,
    editor_open,
    peek,
    ignored,
};
