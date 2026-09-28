//! Pseudo-terminals and the child processes behind them: spawning a
//! command on a pty, its environment, resizing, reading and waiting for its exit.

pub const ChildEnvironment = @import("ChildEnvironment.zig");
pub const Command = @import("Command.zig");
pub const Override = @import("Override.zig");
pub const Session = @import("Session.zig");
pub const Size = @import("Size.zig");
pub const command_support = @import("command_support.zig");
pub const exit = @import("exit.zig");
pub const login_shell = @import("login_shell.zig");

test {
    _ = @import("ChildDescriptor.zig");
    _ = @import("ChildEnvironment.zig");
    _ = @import("ChildFailure.zig");
    _ = @import("Command.zig");
    _ = @import("Configuration.zig");
    _ = @import("Override.zig");
    _ = @import("Session.zig");
    _ = @import("Size.zig");
    _ = @import("command_support.zig");
    _ = @import("environment.zig");
    _ = @import("exit.zig");
    _ = @import("login_shell.zig");
    _ = @import("native.zig");
    _ = @import("native_darwin.zig");
    _ = @import("native_linux.zig");
    _ = @import("pty_tests.zig");
    _ = @import("session_support.zig");
    _ = @import("spawn.zig");
}
