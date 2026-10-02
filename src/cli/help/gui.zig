//! `telar gui --help`.

const FamilyHelp = @import("../FamilyHelp.zig");

pub const family: FamilyHelp = .{
    .summary = "Open the native window; --login-shell adopts the login shell's environment first",
    .usage = "telar gui [--login-shell] [--config PATH | --no-config] [--profile NAME] [--theme NAME] [--remote DESTINATION | --machine LABEL] [--fresh] [COMMAND [ARGS...]]",
    .text =
    \\The same as `telar [options] [COMMAND...]`, which `telar --help` describes: a window
    \\that connects to the local runtime (started when none runs) and every enabled saved
    \\machine, and runs COMMAND or $SHELL in a pane. `--login-shell` re-runs telar through
    \\the user's login shell so a launch from a desktop menu sees the same PATH, EDITOR and
    \\SHELL as a terminal; the flag is removed wherever it appears and never reaches COMMAND.
    \\A window needs a display: without one (Linux without WAYLAND_DISPLAY, an SSH session
    \\on macOS) it exits 1 with a hint to use the CLI. Closing the window leaves the runtime
    \\and its panes running.
    \\
    ,
    .commands = &.{},
};
