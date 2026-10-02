//! `telar config --help` and the help of its commands.

const FamilyHelp = @import("../FamilyHelp.zig");

pub const family: FamilyHelp = .{
    .summary = "Validate the Lua configuration, and reload or read the one a window adopted",
    .usage = "telar config check [PATH] [--profile NAME] | telar config reload|show --client ID [options]",
    .text =
    \\The configuration is Lua, loaded by each window: $TELAR_DEVELOPMENT_CONFIG, else
    \\$XDG_CONFIG_HOME/telar/config.lua, else ~/.config/telar/config.lua. A window
    \\validates a complete replacement before adopting it and keeps the previous one on
    \\failure. The runtime takes its own values from the window that launched it.
    \\
    ,
    .commands = &.{
        .{
            .name = "check",
            .summary = "Compile and validate a configuration, its plugins and keybindings, then exit",
            .usage = "telar config check [PATH] [--profile NAME]",
            .text =
            \\Arguments:
            \\  PATH             The Lua file (default: the configuration a window would load).
            \\  --profile NAME   Overlay that named profile first.
            \\
            \\Effects: loads the file, its plugin registry and keybindings in this process. Starts
            \\nothing, writes nothing.
            \\
            \\Results: `telar config: OK` on stdout, exit 0. Diagnostics on stderr and exit 1 on
            \\a load error, keybindings that do not compile, or a limit reached; retired keys
            \\only warn.
            \\
            ,
            .examples = &.{ &.{ "config", "check" }, &.{ "config", "check", "/home/dev/.config/telar/config.lua", "--profile", "remote" } },
        },
        .{
            .name = "reload",
            .summary = "Make a window reload its configuration now",
            .usage = "telar config reload --client ID [--json] [--socket PATH]",
            .routed = &.{.config_reload},
            .text =
            \\Effects: forwarded to the window `--client ID` names, which schedules a reload even
            \\when no watched file changed. Validation, atomic adoption and trust checks are the
            \\window's; `admitted` reports the request, not adoption. Needs a running runtime;
            \\never starts one.
            \\
            \\Results: text `config_reload: admitted` or the JSON of every routed command. Exit
            \\0; 1 when refused; 2 unknown client; 3 no answer in time. Read the outcome with
            \\`config show`.
            \\
            ,
            .examples = &.{&.{ "config", "reload", "--client", "1" }},
        },
        .{
            .name = "show",
            .summary = "Print a section of the configuration a window adopted",
            .usage = "telar config show --client ID [--section client|theme|gui|input|runtime|binding] [--index N] [--json] [--socket PATH]",
            .routed = &.{.config_show},
            .text =
            \\Arguments:
            \\  --section NAME   `client` (default), `theme`, `gui`, `input`, `runtime` or
            \\                   `binding`, which needs --index N (zero-based; `input` reports
            \\                   `binding_count`).
            \\
            \\Effects: read-only on the window. Lua callbacks appear by generation and
            \\reference, never as code. `runtime` is what the window would launch a runtime
            \\with, not what a running runtime adopted. Needs a running runtime; never starts one.
            \\
            \\Results: always JSON, pretty-printed, or minified with --json. Exit 0; 1 when the
            \\section does not fit the reply; 2 unknown client; 3 no answer in time.
            \\
            ,
            .examples = &.{ &.{ "config", "show", "--client", "1", "--section", "theme" }, &.{ "config", "show", "--client", "1", "--section", "binding", "--index", "0", "--json" } },
        },
    },
};
