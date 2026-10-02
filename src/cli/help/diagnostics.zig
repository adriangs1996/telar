//! `telar diagnostics --help` and the help of its commands.

const std = @import("std");
const FamilyHelp = @import("../FamilyHelp.zig");
const DiagnosticsOptions = @import("../arguments/DiagnosticsOptions.zig");
const DiagnosticLog = @import("../DiagnosticLog.zig");
const diagnostics = @import("../diagnostics.zig");

pub const family: FamilyHelp = .{
    .summary = "Read the runtime's logs beside its socket, and the limits it reached",
    .usage = "telar diagnostics logs|limits [options] [--socket PATH]",
    .text =
    \\Neither command starts a runtime. A limit is a fixed bound telar enforces to keep its
    \\memory fixed; reaching one keeps what fits, drops the excess and counts the reach,
    \\never stops telar. A CLI command that reaches one prints the notice on stderr and
    \\exits nonzero.
    \\
    ,
    .commands = &.{
        .{
            .name = "logs",
            .summary = "Print the tail of the runtime's log and the telemetry logs beside the socket",
            .usage = "telar diagnostics logs [--component all|runtime|client] [--pid N] [--lines N] [--json] [--socket PATH]",
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  --component KIND  `all` (default), `runtime` or `client` telemetry files.
                \\  --pid N          Only the files of that process.
                \\  --lines N        Last lines per file (default {d}, up to {d}).
                \\
                \\Effects: reads `runtime.sock.runtime.log` (the runtime's stderr: reached limits
                \\and a fatal error), `runtime.sock.runtime.start.log` and the per-process
                \\`.runtime-PID.log` and `.client-PID.log` telemetry files, which exist only in
                \\Debug or diagnostics-enabled builds. Never contacts the runtime. Reads at most the
                \\last {d} MiB of each of at most {d} regular, owned files; no terminal content.
                \\
                \\Results: `PATH` (with `(tail)` when cut) followed by the text, per file sorted by
                \\name; JSON an array of `path`, `component`, `pid`, `truncated`, `text`. Exit 0; 2
                \\when no log exists (with the reason); 1 otherwise.
                \\
            , .{ DiagnosticsOptions.default_lines, DiagnosticsOptions.max_lines, DiagnosticLog.max_tail_bytes / (1024 * 1024), diagnostics.max_files }),
            .examples = &.{ &.{ "diagnostics", "logs", "--lines", "200" }, &.{ "diagnostics", "logs", "--component", "runtime", "--json" } },
        },
        .{
            .name = "limits",
            .summary = "List every limit the runtime and its windows reached, with counts and times",
            .usage = "telar diagnostics limits [--json] [--socket PATH]",
            .text =
            \\Effects: one query to a running runtime.
            \\
            \\Results: one line per limit with its value, what was asked, where and when, or
            \\`no limit reached`; JSON `runtime_evicted`, `client_evicted`, `refused_reports`
            \\and `limits` (name, noun, value, requested, route, origin, hits, last_ms). Exit 0;
            \\1 when no runtime answers.
            \\
            ,
            .examples = &.{&.{ "diagnostics", "limits", "--json" }},
        },
    },
};
