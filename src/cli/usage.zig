//! User-facing command-line help.

const std = @import("std");

pub const text =
    \\Usage: telar [--config PATH | --no-config] [--profile NAME] [--theme NAME] [--sidebar-renderer MODE] [command [args...]]
    \\       telar server
    \\       telar server stop
    \\       telar server endpoint
    \\       telar config check [PATH] [--profile NAME]
    \\       telar plugin inspect PATH
    \\       telar plugin install PATH
    \\       telar plugin trust PATH [--capability NAME]...
    \\       telar history list [options]
    \\       telar history search <query> [options]
    \\       telar history import [auto|zsh|bash|fish] [--file PATH]
    \\       telar history show <id>
    \\       telar history delete <id>
    \\       telar history prune [filters] [--before DATE] [--dry-run] [--yes]
    \\       telar notification show <title> [options]
    \\       telar agent list|get|wait|prompt|read [target] [options]
    \\       telar pane read|send-keys <pane|--current> [options]
    \\       telar workspace create --worktree BRANCH [--name NAME] [--directory DIR]
    \\       telar api schema [--json]
    \\       telar integration install|uninstall|status claude [--settings PATH]
    \\       telar hook claude
    \\       telar --skill
    \\
    \\Run an interactive shell inside telar's multiplexer UI.
    \\With a command, run that command instead of $SHELL.
    \\The local runtime starts automatically when needed.
    \\
    \\Commands:
    \\  server           Run the local runtime in the foreground
    \\  server stop      Stop the local runtime
    \\  history list     Show recent command history
    \\  history search   Search command history
    \\  history import   Import an existing shell histfile
    \\  history show     Print an entry's captured output
    \\  history delete   Remove one exact history entry
    \\  history prune    Remove every entry matching the filters
    \\  notification show  Show a toast in every connected UI client
    \\  agent list       List the agents the runtime knows about
    \\  agent get        Show one agent by pane id, title or --current
    \\  agent wait       Block until an agent reaches a status (default: done)
    \\  agent prompt     Send a prompt to an agent; refused while it is blocked
    \\  agent read       Print recent text from an agent's pane
    \\  agent report-session  Record an agent's own session id for restore
    \\  pane read        Print recent text from any pane
    \\  pane send-keys   Send raw text (and --enter) to any pane
    \\  workspace create Add a git worktree and open a workspace on it
    \\  api schema       Print the wire contract of this binary
    \\  integration      Register telar's lifecycle hooks in an agent's settings
    \\  hook             Entry point that agent hooks run (reads JSON on stdin)
    \\  --skill          Print the bundled agent skill
    \\  config check     Compile and validate config.lua, then exit
    \\  plugin inspect   Validate a package and print its immutable identity
    \\  plugin install   Copy a package into the content-addressed local store
    \\  plugin trust     Grant declared capabilities to one exact package digest
    \\
    \\History options:
    \\  --cwd            Restrict results to the current directory
    \\  --workspace PATH Restrict results to a workspace path
    \\  --pane ID        Restrict results to a pane
    \\  --failed         Only show commands with a non-zero exit status
    \\  --limit N        Return at most N results (default 20, maximum 100)
    \\  --socket PATH    Query a specific local runtime
    \\
    \\Agent and pane options:
    \\  --until STATUS   done, ready, blocked, working, failed (wait)
    \\  --timeout SECS   Give up after SECS seconds (wait, prompt --wait)
    \\  --wait           Wait for the agent to finish after prompting
    \\  --lines N        Rows to read (default 40, maximum 200)
    \\  --source KIND    recent (scrollback + screen) or screen
    \\  --enter          Append Enter after the sent text
    \\  --json           Print JSON instead of rows
    \\  --socket PATH    Address a specific local runtime
    \\
    \\Notification options:
    \\  --body TEXT      Add detail text below the title
    \\  --level LEVEL    info, success, warning, or failure
    \\  --duration MS    Keep it visible for 500..60000 ms (default 4000)
    \\  --pane ID        Make it focus a pane when clicked
    \\  --tab ID         Make it select a tab when clicked
    \\  --workspace ID   Make it select a workspace when clicked
    \\  --socket PATH    Notify clients of a specific local runtime
    \\
    \\Remote:
    \\  --remote DEST    Attach to the runtime on an SSH host (forwards its
    \\                   socket; needs telar on the remote PATH)
    \\
    \\Options:
    \\  --config PATH     Load a specific Lua configuration
    \\  --no-config       Do not load Lua configuration
    \\  --profile NAME    Overlay a named Lua profile before CLI options
    \\  --theme NAME      UI theme: vesper, catppuccin, tokyo-night, terminal
    \\  --sidebar-renderer MODE  automatic, cells, kitty-hybrid, kitty-full
    \\Server options:
    \\  --graphics-pane-mib N    Decoded KGP memory per pane (default 64)
    \\  --graphics-global-mib N  Decoded KGP memory for the runtime (default 256)
    \\  -h, --help       Show this help
    \\  -V, --version    Show the version
    \\  --               Stop parsing telar options
    \\
    \\Default keybindings (prefix Ctrl-b):
    \\  % / "             Split left/right or top/bottom
    \\  Arrow keys       Focus a pane by direction
    \\  Shift+arrows     Resize the focused pane
    \\  z                Toggle pane fullscreen
    \\  s                Toggle the sidebar
    \\  w                Toggle the workspace list
    \\  N                Create and select a workspace
    \\  W                Rename the active workspace
    \\  x                Close the focused pane
    \\  [                Enter copy mode
    \\  g                Open the goto picker
    \\  /                Search command history
    \\  c                Create and select a tab
    \\  n / p            Select the next or previous tab
    \\  1..9             Select a tab by position
    \\  T                Rename the active tab
    \\  X                Close the active tab
    \\  , / .            Move the active tab left or right
    \\  d                Detach the client
    \\
;

test "usage names every public subcommand" {
    for ([_][]const u8{
        "server",
        "server stop",
        "config check",
        "plugin inspect",
        "plugin install",
        "plugin trust",
        "history list",
        "history search",
        "notification show",
        "workspace create",
    }) |command| {
        try std.testing.expect(std.mem.indexOf(u8, text, command) != null);
    }
}
