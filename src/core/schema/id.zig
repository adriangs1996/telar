//! Strong identifiers used by the protocol and runtime model.

pub const WorkspaceId = enum(u64) {
    invalid = 0,
    _,
};

pub const WorktreeId = enum(u64) {
    invalid = 0,
    _,
};

pub const TabId = enum(u64) {
    invalid = 0,
    _,
};

pub const PaneId = enum(u64) {
    invalid = 0,
    _,
};

pub const RequestId = enum(u64) {
    /// Reserved for failures that are not associated with a request.
    none = 0,
    _,
};

pub fn workspace(value: u64) !WorkspaceId {
    if (value == 0) return error.InvalidWorkspaceId;
    return @enumFromInt(value);
}

pub fn worktree(value: u64) !WorktreeId {
    if (value == 0) return error.InvalidWorktreeId;
    return @enumFromInt(value);
}

pub fn tab(value: u64) !TabId {
    if (value == 0) return error.InvalidTabId;
    return @enumFromInt(value);
}

pub fn pane(value: u64) !PaneId {
    if (value == 0) return error.InvalidPaneId;
    return @enumFromInt(value);
}

pub fn request(value: u64) !RequestId {
    if (value == 0) return error.InvalidRequestId;
    return @enumFromInt(value);
}

pub fn raw(value: anytype) u64 {
    return @intFromEnum(value);
}
