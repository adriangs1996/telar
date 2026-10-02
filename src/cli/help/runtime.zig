//! `telar runtime --help` and the help of its commands.

const FamilyHelp = @import("../FamilyHelp.zig");

pub const family: FamilyHelp = .{
    .summary = "Ask a running runtime whether it runs, how the host is doing, and watch its events",
    .usage = "telar runtime status|metrics|watch [--json] [--count N] [--socket PATH]",
    .text =
    \\These never start a runtime: `status` is the way to learn whether one runs. The
    \\runtime answers through `--socket PATH`, else $TELAR_SOCKET, else TELAR_SOCKET_PATH of
    \\this pane, else $XDG_RUNTIME_DIR/telar/runtime.sock. Exit codes: 0; 1 when none runs
    \\or it refused; 3 when it did not answer within 30 s.
    \\
    ,
    .commands = &.{
        .{
            .name = "status",
            .summary = "Report that the runtime runs, its wire schema and its proxy status",
            .usage = "telar runtime status [--json] [--socket PATH]",
            .text =
            \\Effects: a handshake and one query; read-only.
            \\
            \\Results: `Runtime: running`, `Schema: N`, `Proxy: active|disabled` with its port,
            \\scope and system trust when active; JSON `running`, `schema_version`, `proxy`.
            \\Exit 0; 1 when no runtime answers at the socket.
            \\
            ,
            .examples = &.{&.{ "runtime", "status", "--json" }},
        },
        .{
            .name = "metrics",
            .summary = "Print the runtime's latest sample of CPU, memory and battery",
            .usage = "telar runtime metrics [--json] [--socket PATH]",
            .text =
            \\Effects: waits for the runtime's next sampled metrics; read-only. Compare machines
            \\with `telar --machine LABEL runtime metrics --json` before choosing one.
            \\
            \\Results: text CPU percent, memory in GiB and battery; JSON `revision`,
            \\`cpu_percent`, `cpu_count`, `memory_used_decigib`, `memory_total_decigib` (tenths
            \\of a GiB), `battery_percent` (null without a battery). Exit 0.
            \\
            ,
            .examples = &.{&.{ "runtime", "metrics", "--json" }},
        },
        .{
            .name = "watch",
            .summary = "Stream the runtime's global events as JSON lines",
            .usage = "telar runtime watch [--jsonl] [--count N] [--socket PATH]",
            .text =
            \\Arguments:
            \\  --count N        Exit after N events (default: until the runtime stops).
            \\
            \\Effects: subscribes as an observer; keeps no history, polls nothing.
            \\
            \\Results: one JSON object per line with `type` `proxy_status`, `system_metrics`,
            \\`runtime_stopping`, `resync_required`, `workspace_list` or `agent_snapshot` (the
            \\last two with `revision` and `data`). Exit 0 after --count events or when the
            \\runtime stops; 1 after a resync notice (reconnect for a fresh snapshot).
            \\
            ,
            .examples = &.{&.{ "runtime", "watch", "--jsonl", "--count", "5" }},
        },
    },
};
