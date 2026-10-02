//! `telar server --help` and the help of its commands.

const std = @import("std");
const core = @import("telar-core");
const FamilyHelp = @import("../FamilyHelp.zig");

pub const family: FamilyHelp = .{
    .summary = "Run the local runtime in the foreground, stop it, or print its endpoint",
    .usage = "telar server [--fresh] [--socket PATH] [--graphics-pane-mib N] [--graphics-global-mib N] [--config PATH | --no-config] [--profile NAME]\n       telar server stop|endpoint [--socket PATH]",
    .text = std.fmt.comptimePrint(
        \\The runtime is one long-lived process per account that owns the panes, their
        \\children, the agents and the history, so a window may come and go. Commands that
        \\need it start it in the background on their own; `telar server` runs it in this
        \\process instead, until stopped.
        \\
        \\Arguments:
        \\  --fresh          Set the previous session checkpoint aside (`session.ckpt.previous`)
        \\                   instead of restoring it. Refused while a runtime is already running.
        \\  --socket PATH    Listen at PATH instead of $XDG_RUNTIME_DIR/telar/runtime.sock.
        \\  --graphics-pane-mib N, --graphics-global-mib N
        \\                   Decoded image memory per pane and for the runtime (defaults {d} and
        \\                   {d} MiB).
        \\  --config, --no-config, --profile  The Lua configuration the runtime takes its
        \\                   values from, as a window would.
        \\  --background, --daemonized  How telar starts a runtime for itself; not for typing.
        \\
        \\Results: `telar server` runs until stopped and exits 0, or 1 after a proxy tunnel kept
        \\the shutdown waiting. A second runtime on the same socket fails to bind.
        \\
    , .{ core.max_image_bytes_per_pane / (1024 * 1024), core.max_image_bytes_global / (1024 * 1024) }),
    .commands = &.{
        .{
            .name = "stop",
            .summary = "Ask the local runtime to stop",
            .usage = "telar server stop [--socket PATH]",
            .text =
            \\Effects: sends the stop request; the runtime writes its session checkpoint, closes
            \\its panes' children and exits. Never starts a runtime.
            \\
            \\Results: `telar runtime is stopping`, or `telar runtime is not running`; exit 0 in
            \\both cases, 1 when the runtime refused.
            \\
            ,
            .examples = &.{&.{ "server", "stop" }},
        },
        .{
            .name = "endpoint",
            .summary = "Make sure a runtime runs and print its socket path and wire schema",
            .usage = "telar server endpoint [--socket PATH]",
            .text =
            \\Effects: starts the runtime in the background when none runs. This is what
            \\`telar machine check` and `--remote` run over SSH to discover a machine.
            \\
            \\Results: two lines, the socket path and the schema id. Exit 0.
            \\
            ,
            .examples = &.{&.{ "server", "endpoint" }},
        },
        .{
            .name = "bridge",
            .summary = "Relay standard input and output to the runtime's socket, for SSH",
            .usage = "telar server bridge [--socket PATH]",
            .hidden = true,
            .text =
            \\Run over SSH by a window attaching with `--remote`; not meant to be typed.
            \\
            ,
            .examples = &.{&.{ "server", "bridge" }},
        },
    },
};
