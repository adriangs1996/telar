//! Application command for removing one pane from a client session.

pub const DetachPaneResult = enum {
    detached,
    not_attached,
};

pub const Effect = enum {
    detach,
    leave_workspace,
    release,
};
