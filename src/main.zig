const std = @import("std");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
const cli_mod = @import("cli/root.zig");

const Io = std.Io;
const File = Io.File;
const pty = backend.pty;

const version = "0.0.0";

// Library warnings cannot be written over a live frame. A later runtime can
// route them to its log; the bootstrap keeps stderr out of the drawing path.
pub const std_options: std.Options = .{ .log_level = .err };

const Cli = cli_mod.Cli;

fn collectArgs(init: std.process.Init, storage: *[pty.max_args][*:0]const u8) ![]const [*:0]const u8 {
    var iterator = init.minimal.args.iterate();
    var len: usize = 0;
    while (iterator.next()) |arg| {
        if (len == storage.len) return error.TooManyArguments;
        storage[len] = arg.ptr;
        len += 1;
    }
    return storage[0..len];
}

const usage =
    \\Usage: telar [--config PATH | --no-config] [--profile NAME] [--theme NAME] [--sidebar-renderer MODE] [command [args...]]
    \\       telar server
    \\       telar server stop
    \\       telar config check [PATH] [--profile NAME]
    \\       telar plugin inspect PATH
    \\       telar plugin install PATH
    \\       telar plugin trust PATH [--capability NAME]...
    \\       telar history list [options]
    \\       telar history search <query> [options]
    \\       telar notification show <title> [options]
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
    \\  notification show  Show a toast in every connected UI client
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
    \\Notification options:
    \\  --body TEXT      Add detail text below the title
    \\  --level LEVEL    info, success, warning, or failure
    \\  --duration MS    Keep it visible for 500..60000 ms (default 4000)
    \\  --pane ID        Make it focus a pane when clicked
    \\  --tab ID         Make it select a tab when clicked
    \\  --workspace ID   Make it select a workspace when clicked
    \\  --socket PATH    Notify clients of a specific local runtime
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
    \\  c                Create and select a tab
    \\  n / p            Select the next or previous tab
    \\  1..9             Select a tab by position
    \\  T                Rename the active tab
    \\  X                Close the active tab
    \\  , / .            Move the active tab left or right
    \\  d                Detach the client
    \\
;

pub fn main(init: std.process.Init) !void {
    var arg_storage: [pty.max_args][*:0]const u8 = undefined;
    const args = try collectArgs(init, &arg_storage);

    switch (try Cli.parse(args, init.minimal.environ)) {
        .help => try File.stdout().writeStreamingAll(init.io, usage),
        .version => try File.stdout().writeStreamingAll(init.io, "telar " ++ version ++ "\n"),
        .server => |options| try cli_mod.server.run(init, options),
        .history => |options| try cli_mod.history.run(init, options),
        .notification => |options| try cli_mod.notification.run(init, options),
        .config_check => |options| try cli_mod.config.runCheck(init, options),
        .plugin_worker => |options| try frontend.plugins.runWorker(
            init,
            std.mem.span(options.entry),
            std.mem.span(options.action),
            options.context,
        ),
        .plugin => |options| try cli_mod.plugin.run(init, options),
        .run => |options| {
            std.process.exit(try cli_mod.client.run(init, options));
        },
    }
}
