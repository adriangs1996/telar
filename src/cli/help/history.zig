//! `telar history --help` and the help of its commands.

const std = @import("std");
const core = @import("telar-core");
const FamilyHelp = @import("../FamilyHelp.zig");
const history = @import("../history.zig");

const filters_text = std.fmt.comptimePrint(
    \\Filters:
    \\  --cwd            Only the current directory.
    \\  --workspace PATH Only that workspace directory.
    \\  --pane ID        Only that pane.
    \\  --failed         Only commands that exited nonzero.
    \\  --author all|human|agent  Who typed it (default all).
    \\  --limit N        At most N entries (default 20, up to {d}).
, .{core.max_history_results});

pub const family: FamilyHelp = .{
    .summary = "Search, show, import, prune and summarize the command history the runtime records",
    .usage = "telar history COMMAND [ARG] [filters] [--socket PATH]",
    .text = std.fmt.comptimePrint(
        \\The runtime records commands detected through shell integration and agent hooks, with their
        \\directory, exit status, duration and, when `runtime.history.output` is enabled, their
        \\output; the database lives under $XDG_DATA_HOME/telar. These commands query the
        \\runtime and start it when none runs. This is not a complete audit log.
        \\Text output only. One scope filter at a time.
        \\
        \\{s}
        \\
    , .{filters_text}),
    .commands = &.{
        .{
            .name = "list",
            .summary = "Show recent commands",
            .usage = "telar history list [--cwd | --workspace PATH | --pane ID] [--failed] [--author all|human|agent] [--limit N] [--socket PATH]",
            .text =
            \\Results: one line per entry: `#ID  DATE TIMEZ  STATUS  DURATIONms  CWD  [provider]
            \\COMMAND`, newest first; STATUS is `RUN`, `INT`, the exit code or `?`; `[provider]`
            \\marks an agent's command. Exit 0.
            \\
            ,
            .examples = &.{ &.{ "history", "list", "--cwd", "--limit", "50" }, &.{ "history", "list", "--author", "agent", "--failed" } },
        },
        .{
            .name = "search",
            .summary = "Search commands by text",
            .usage = "telar history search QUERY [filters] [--socket PATH]",
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  QUERY            The text to find; at most {d} bytes.
                \\
                \\Results: as `history list`. Exit 0.
                \\
            , .{core.max_history_query_bytes}),
            .examples = &.{&.{ "history", "search", "git commit", "--workspace", "/home/dev/telar", "--limit", "40" }},
        },
        .{
            .name = "show",
            .summary = "Print the output captured for one entry",
            .usage = "telar history show ID [--socket PATH]",
            .text =
            \\Results: the raw output on stdout; a note on stderr when nothing was captured
            \\(`runtime.history.output = "bounded"` enables capture) or it was cut. Exit 0.
            \\
            ,
            .examples = &.{&.{ "history", "show", "42" }},
        },
        .{
            .name = "import",
            .summary = "Import an existing shell histfile once; running it again adds only new lines",
            .usage = "telar history import [auto|zsh|bash|fish] [--file PATH] [--socket PATH]",
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  KIND             The histfile format (default `auto`: by the file's name, else
                \\                   ~/.zsh_history, ~/.bash_history, then fish's).
                \\  --file PATH      The file to read instead of the shell's default.
                \\
                \\Effects: the entries join the history under a source pinned to the file, so an
                \\import is safe to repeat. A file past {d} MiB keeps its newest lines; a command
                \\past {d} KiB is skipped; either reports the limit and exits 1.
                \\
                \\Results: `imported N commands from PATH`. Exit 0; 1 when no histfile was found.
                \\
            , .{ history.max_histfile_bytes / (1024 * 1024), core.max_import_command_bytes / 1024 }),
            .examples = &.{ &.{ "history", "import" }, &.{ "history", "import", "fish", "--file", "/home/dev/.local/share/fish/fish_history" } },
        },
        .{
            .name = "delete",
            .summary = "Remove one entry, without asking",
            .usage = "telar history delete ID [--socket PATH]",
            .text =
            \\Results: `removed N entries`. Exit 0.
            \\
            ,
            .examples = &.{&.{ "history", "delete", "42" }},
        },
        .{
            .name = "prune",
            .summary = "Remove every entry matching the filters, after a preview and a confirmation",
            .usage = "telar history prune [filters] [--match TEXT] [--before DATE] [--dry-run] [--yes] [--socket PATH]",
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  --match TEXT     Only commands containing TEXT.
                \\  --before DATE    Only entries before `YYYY-MM-DD` (UTC) or a Unix time in seconds.
                \\  --dry-run        Preview only, even with --yes.
                \\  --yes            Skip the confirmation.
                \\
                \\Effects: previews `would remove N entries` (counting the newest {d}; --before is
                \\applied on top and not previewed), asks `prune permanently? type yes to
                \\continue:` and removes on `yes`. --author is not applied to prune.
                \\
                \\Results: `removed N entries`, or `aborted`. Exit 0.
                \\
            , .{core.max_history_results}),
            .examples = &.{ &.{ "history", "prune", "--before", "2025-01-01", "--dry-run" }, &.{ "history", "prune", "--match", "rm -rf", "--yes" } },
        },
        .{
            .name = "stats",
            .summary = "Count commands and show the most frequent ones over a period",
            .usage = "telar history stats [--period today|week|month|year|all] [--cwd | --workspace PATH | --pane ID] [--socket PATH]",
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  --period P       `today`, `week`, `month`, `year` or `all` (default).
                \\
                \\Results: `commands: N`, `unique: N` and the top {d} commands with their counts.
                \\Only the scope and the period filter; --failed, --author and --limit are
                \\ignored here. Exit 0.
                \\
            , .{core.max_history_stats_top}),
            .examples = &.{&.{ "history", "stats", "--period", "week" }},
        },
    },
};
