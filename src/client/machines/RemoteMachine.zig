//! A machine one client reaches over SSH: its destination, where telar
//! lives there (null runs `telar` from the PATH), and the command its first
//! pane runs (the login shell when empty).
const RemoteMachine = @This();

destination: []const u8,
telar_path: ?[]const u8 = null,
arguments: []const []const u8 = &.{},
