//! `telar command --help` and the help of its commands.

const std = @import("std");
const core = @import("telar-core");
const FamilyHelp = @import("../FamilyHelp.zig");

pub const family: FamilyHelp = .{
    .summary = "Ask the runtime's engine for a shell command from a description, in a pane's context",
    .usage = "telar command suggest PANE|--current TEXT [--json] [--socket PATH]",
    .commands = &.{
        .{
            .name = "suggest",
            .summary = "Suggest one command line for a pane from words; prints it, never runs it",
            .usage = "telar command suggest PANE|--current TEXT [--json] [--socket PATH]",
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  PANE|--current   The pane whose working directory and screen give the context.
                \\  TEXT             What the command should do; 1 to {d} bytes of UTF-8.
                \\
                \\Effects: the runtime's engine (a headless agent of its own) answers one command
                \\line. Nothing is typed anywhere. Needs a running runtime with an engine configured;
                \\never starts one.
                \\
                \\Results: the suggestion on stdout; JSON `status` (ready|unavailable|timeout|failed)
                \\and `command`. Exit 0 when ready, 3 on timeout, 1 when unavailable or failed.
                \\
            , .{core.max_suggestion_request_bytes}),
            .examples = &.{&.{ "command", "suggest", "--current", "list the largest files here", "--json" }},
        },
    },
};
