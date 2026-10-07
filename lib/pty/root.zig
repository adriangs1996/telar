//! Pseudo-terminals and the child processes behind them: spawning a
//! command on a pty, its environment, resizing, reading and waiting for its exit.

pub const ChildEnvironment = @import("ChildEnvironment.zig");
pub const Command = @import("Command.zig");
pub const Override = @import("Override.zig");
pub const Session = @import("Session.zig");
pub const Size = @import("Size.zig");
pub const command_support = @import("command_support.zig");
pub const descriptor_limit = @import("descriptor_limit.zig");
pub const exit = @import("exit.zig");
pub const login_shell = @import("login_shell.zig");
