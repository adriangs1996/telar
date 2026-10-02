//! `telar exec --help` and the help of its commands.

const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const FamilyHelp = @import("../FamilyHelp.zig");
const execution = @import("../execution.zig");

const reply_text =
    \\Results: JSON `execution_id`, `workspace_id`, `state` (starting|running|exited|failed),
    \\`exit_code` (null until exited), `stdout_offset`, `stderr_offset`, `stdout_bytes`,
    \\`stderr_bytes`, `stdin_bytes`, `stdin_open`, `failure`.
;

pub const family: FamilyHelp = .{
    .summary = "Run a literal command under the runtime without a terminal, and observe, cancel or release its result",
    .usage = "telar exec [options] -- PROGRAM ARGS...\n       telar exec list|status|output|cancel|forget [ID] [options]",
    .text = std.fmt.comptimePrint(
        \\An execution is a runtime-owned command with pipes, not a pane: literal argv, no
        \\shell, no PTY, stdout and stderr kept apart. Its id and bounded output outlive the
        \\connection that started it and the workspace it ran in, for one runtime lifetime,
        \\until `forget`. Timeouts and disconnects leave it running. For a command that needs
        \\a terminal use `telar workspace create -- COMMAND` or `telar worktree exec`.
        \\
        \\Ids are the destination runtime's: with `telar --machine LABEL exec`, that machine's.
        \\Bounds: {d} retained executions, {d} argv words, {d} KiB of argument bytes, the
        \\newest {d} MiB kept per output stream, a {d} KiB stdin queue. Exit codes: the
        \\child's; {d} when `--timeout` passed; {d} when the runtime or transport failed or
        \\refused (a child may exit with these too: `exec status` tells).
        \\
    , .{ backend.Executions.capacity, core.ExecutionRequest.max_arguments, core.ExecutionRequest.max_launch_bytes / 1024, backend.ExecutionPipes.retained_bytes / (1024 * 1024), backend.ExecutionPipes.input_bytes / 1024, execution.timeout_status, execution.failure_status }),
    .commands = &.{
        .{
            .name = "start",
            .summary = "Start a command (the word `start` may be left out); the default when `--` follows",
            .usage = "telar exec start [--id N] [--workspace ID] [--cwd ABS] [--detach --json] [--no-stdin] [--timeout SECONDS] [--socket PATH] -- PROGRAM ARGS...\n       telar exec [options] -- PROGRAM ARGS...",
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  -- PROGRAM ARGS  Literal argv, 1 to {d} words; a shell is explicit
                \\                   (`-- /bin/sh -c 'printf hello'`). PROGRAM resolves on the
                \\                   runtime's PATH.
                \\  --id N           A nonzero id of your choice (default: random). Starting again
                \\                   with the same id and arguments finds the same execution; with
                \\                   other arguments it is refused.
                \\  --workspace ID   Run in that workspace's directory (the destination runtime's id).
                \\                   Default: the runtime's own Administration workspace at its HOME,
                \\                   created and removed as needed, independent of any window.
                \\  --cwd ABS        An explicit absolute working directory on the destination.
                \\  --detach --json  Return at once with the execution's JSON instead of its bytes.
                \\  --no-stdin       Close the child's input at once.
                \\  --timeout S      Stop waiting after S seconds (default: wait until exit); the
                \\                   execution keeps running, stdin closes.
                \\
                \\Effects: the runtime spawns PROGRAM in its own process group with the runtime's
                \\environment (minus the pane variables and SSH_AUTH_SOCK), and keeps its result.
                \\Starts the local runtime when none runs. In the foreground this process copies
                \\stdin to the child and the child's stdout and stderr to its own, byte for byte, with
                \\no metadata; stdin closes at EOF, on timeout or on disconnect, never cancelling.
                \\
                \\Results: foreground, exit with the child's status (signals as 128+n), {d} on
                \\timeout, {d} on a runtime or transport failure; when the start is uncertain, stderr
                \\names the id to query before retrying. Detached: {s}
                \\
            , .{ core.ExecutionRequest.max_arguments, execution.timeout_status, execution.failure_status, reply_text }),
            .examples = &.{ &.{ "exec", "--no-stdin", "--", "/usr/bin/uname", "-a" }, &.{ "exec", "--id", "829341", "--detach", "--json", "--", "/bin/sh", "-c", "sleep 30; echo done" }, &.{ "exec", "start", "--cwd", "/tmp", "--timeout", "60", "--", "ls" } },
        },
        .{
            .name = "list",
            .summary = "List retained executions with their state and exit code",
            .usage = "telar exec list [--json] [--socket PATH]",
            .text =
            \\Effects: reads the runtime's execution table. Starts the local runtime when none runs.
            \\
            \\Results: always a JSON array of `execution_id`, `workspace_id`, `state`, `exit_code`,
            \\in ascending id order, including foreground executions whose streams carried no id.
            \\Exit 0.
            \\
            ,
            .examples = &.{&.{ "exec", "list", "--json" }},
        },
        .{
            .name = "status",
            .summary = "Show one execution's state, exit code, stream counters and failure",
            .usage = "telar exec status ID [--json] [--socket PATH]",
            .text = std.fmt.comptimePrint(
                \\Effects: read-only. Starts the local runtime when none runs.
                \\
                \\{s} Exit 0; {d} when the id is unknown.
                \\
            , .{ reply_text, execution.failure_status }),
            .examples = &.{&.{ "exec", "status", "829341" }},
        },
        .{
            .name = "output",
            .summary = "Print retained stdout and stderr bytes from given offsets",
            .usage = "telar exec output ID [--stdout-offset N] [--stderr-offset N] [--socket PATH]",
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  --stdout-offset N, --stderr-offset N  Byte cursors to read from (default 0).
                \\
                \\Effects: writes a snapshot of the retained bytes, stdout to stdout and stderr to
                \\stderr, up to the totals at the time of the request. Moves no one else's cursor.
                \\Starts the local runtime when none runs.
                \\
                \\Results: the bytes; exit 0. Only the newest {d} MiB per stream is kept: a cursor
                \\that fell behind gets the retained start and total counters and exit {d}, never a
                \\silently incomplete artifact. For a file, use `telar file get` through exec.
                \\
            , .{ backend.ExecutionPipes.retained_bytes / (1024 * 1024), execution.failure_status }),
            .examples = &.{&.{ "exec", "output", "829341", "--stdout-offset", "4096" }},
        },
        .{
            .name = "cancel",
            .summary = "Kill an execution's process group",
            .usage = "telar exec cancel ID [--json] [--socket PATH]",
            .text = std.fmt.comptimePrint(
                \\Effects: SIGKILL to the execution's own process group; descendants that left the
                \\group are outside its ownership. Starts the local runtime when none runs.
                \\
                \\{s} Query `status` for the final state. Exit 0; {d} when unknown.
                \\
            , .{ reply_text, execution.failure_status }),
            .examples = &.{&.{ "exec", "cancel", "829341" }},
        },
        .{
            .name = "forget",
            .summary = "Release a finished execution's id and retained output",
            .usage = "telar exec forget ID [--json] [--socket PATH]",
            .text = std.fmt.comptimePrint(
                \\Effects: frees the slot; refused while the execution runs. Results are never
                \\evicted on their own, so forget what you have read. Starts the local runtime when
                \\none runs.
                \\
                \\{s} Exit 0; {d} when unknown or still running.
                \\
            , .{ reply_text, execution.failure_status }),
            .examples = &.{&.{ "exec", "forget", "829341" }},
        },
    },
};
