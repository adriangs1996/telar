//! A machine one client reaches over SSH: its destination and the command
//! its first pane runs (the login shell when empty).
const RemoteMachine = @This();

destination: []const u8,
arguments: []const []const u8 = &.{},
