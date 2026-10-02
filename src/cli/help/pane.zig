//! `telar pane --help` and the help of its commands.

const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const FamilyHelp = @import("../FamilyHelp.zig");
const PaneOptions = @import("../arguments/PaneOptions.zig");
const pane = @import("../pane.zig");
const values = @import("../arguments/values.zig");

/// What the commands that act through a window share.
const routed_text =
    \\Effects: the runtime forwards the request to the window `--client ID` names (see
    \\`telar client list`); the pane must be in that window's active tab. Needs a running
    \\runtime; never starts one. Results: text `ACTION: STATUS` or JSON `client_id`,
    \\`client_generation`, `action`, `status`, `target_id`, `value`, `text`. `applied`
    \\means done; `admitted` means the window queued it and the runtime confirms the
    \\change later (check with `pane list` or `tab get`). Exit 0; 1 when the window
    \\refused (its reason on stderr); 2 unknown client; 3 the window did not answer in time.
;

pub const family: FamilyHelp = .{
    .summary = "Read, type into and watch any pane; list panes; and, through a window, split, close, focus, resize and scroll them",
    .usage = "telar pane COMMAND [ID|--current] [options]",
    .text = std.fmt.comptimePrint(
        \\A pane is one terminal the runtime owns; a pane id names it for its whole life, and
        \\its generation changes when its command is relaunched. `--current` is this pane,
        \\from TELAR_PANE_ID. Titles are not accepted here: use `telar agent` for agents.
        \\
        \\`read`, `send-keys`, `search`, `watch`, `list` and `get` work on the runtime alone
        \\without selecting a window; input can change the pane's visible output.
        \\`create`, `split`, `close`, `focus ID`, `resize`,
        \\`fullscreen`, `scroll` and `copy` act through one attached window (`--client ID`),
        \\whose layout and focus belong to that window. Exit codes: 0; 2 the pane is gone;
        \\1 anything else, with the reason on stderr. A pane a person has focused in an
        \\attached window refuses text (`pane_focused`): open your own tab with `telar tab
        \\create --background` instead of typing where they may be typing.
        \\
        \\Limits: text read {d} rows / {d} KiB, text sent {d} KiB.
        \\
    , .{ core.max_pane_text_rows, core.max_pane_text_bytes / 1024, core.max_pane_text_input_bytes / 1024 }),
    .commands = &.{
        .{
            .name = "read",
            .summary = "Print recent text from any pane",
            .usage = "telar pane read ID|--current [--lines N] [--source recent|screen] [--json] [--socket PATH]",
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  --lines N        Rows to return, counted up from the last row with text (default
                \\                   {d}, up to {d}).
                \\  --source KIND    `recent` (scrollback and screen, default) or `screen` (visible).
                \\
                \\Effects: read-only snapshot; no input, no attachment. Starts the local runtime when
                \\none runs.
                \\
                \\Results: the text; JSON `pane_id`, `truncated`, `exit_code` (null while running),
                \\`text`. Up to {d} KiB, newest rows kept; `truncated` means older rows were dropped
                \\(stderr says so in text mode, as it names the exit code of a finished pane). A
                \\finished pane keeps {d} rows within {d} KiB while it is among the last {d} that
                \\exited; then exit 2.
                \\
            , .{ values.default_read_rows, core.max_pane_text_rows, core.max_pane_text_bytes / 1024, backend.ExitedPanes.kept_rows, backend.ExitedPanes.max_text_bytes / 1024, backend.ExitedPanes.capacity }),
            .examples = &.{ &.{ "pane", "read", "4", "--lines", "100" }, &.{ "pane", "read", "--current", "--source", "screen", "--json" } },
        },
        .{
            .name = "send-keys",
            .summary = "Send raw text, or --stdin, (and --enter) to a pane no person has focused",
            .usage = "telar pane send-keys ID|--current TEXT|--stdin [--enter] [--json] [--socket PATH]",
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  TEXT             1 to {d} bytes, typed as is (no Enter unless --enter).
                \\  --stdin          Read the text from standard input instead (third word, in
                \\                   place of TEXT), so it never shows in a process list; trailing
                \\                   newlines are trimmed.
                \\  --enter          Press Enter {d} ms after the text, so an agent that reads fast
                \\                   typing as a paste still submits it.
                \\
                \\Effects: the runtime writes the bytes to the pane's terminal, whatever runs there.
                \\Not refused while an agent is blocked: this is how a blocked agent's question is
                \\answered, after reading it with `pane read` and only as the user authorized.
                \\Refused when a person has the pane focused. Starts the local runtime when none runs.
                \\For a prompt to an agent prefer `telar agent prompt`, which waits and is budgeted.
                \\
                \\Results: nothing; exit 0, 1 when refused, 2 when the pane is gone.
                \\
            , .{ core.max_pane_text_input_bytes, pane.submit_delay_ms }),
            .examples = &.{ &.{ "pane", "send-keys", "4", "pwd", "--enter" }, &.{ "pane", "send-keys", "--current", "--stdin" } },
        },
        .{
            .name = "search",
            .summary = "Find text in a pane's retained history, without attaching",
            .usage = "telar pane search ID|--current TEXT [--json] [--socket PATH]",
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  TEXT             1 to {d} bytes of UTF-8.
                \\
                \\Effects: the runtime searches the pane's scrollback and screen within a bounded
                \\time. Read-only; needs a running runtime, never starts one.
                \\
                \\Results: one `ROW:COLUMN length=N` per match in absolute history coordinates; JSON
                \\`pane_id`, `truncated`, `matches` (x, y, len). At most {d} matches, the newest
                \\kept; `truncated` means the search ran out of rows or time. Exit 0; 2 when the pane
                \\is gone; 1 when it changed during the search (retry).
                \\
            , .{ core.max_search_needle_bytes, core.max_search_matches }),
            .examples = &.{&.{ "pane", "search", "4", "error:", "--json" }},
        },
        .{
            .name = "watch",
            .summary = "Emit a pane's text as JSON lines whenever it changes, by polling",
            .usage = "telar pane watch ID|--current [--count N] [--interval-ms N] [--lines N] [--source recent|screen] [--workspace ID [--tab ID]] [--jsonl] [--socket PATH]",
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  --count N        Stop after N changes (default: until killed).
                \\  --interval-ms N  Poll every N ms (default {d}, {d} to {d}).
                \\  --lines N, --source KIND  As `pane read`.
                \\  --workspace, --tab  Scope the lookup of the pane's generation.
                \\
                \\Effects: reads the topology once to pin the pane's generation, then polls `read`
                \\and prints a line only when the text changed. Not a byte stream: changes between
                \\two polls are coalesced. Needs a running runtime; never starts one.
                \\
                \\Results: always JSON lines `pane_id`, `pane_generation`, `truncated`, `text`.
                \\Exit 0 after --count changes; 2 when the pane is gone.
                \\
            , .{ PaneOptions.default_interval_ms, PaneOptions.min_interval_ms, PaneOptions.max_interval_ms }),
            .examples = &.{&.{ "pane", "watch", "4", "--count", "3", "--interval-ms", "500", "--lines", "20" }},
        },
        .{
            .name = "list",
            .summary = "List every pane with its workspace, tab, generation and lifecycle",
            .usage = "telar pane list [--workspace ID|--current [--tab ID|--current]] [--json] [--socket PATH]",
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  --workspace, --tab  Restrict to one workspace or one tab of it (`--current` reads
                \\                   TELAR_WORKSPACE_ID / TELAR_TAB_ID); --tab needs --workspace.
                \\
                \\Effects: walks the runtime's workspace and tab snapshots; attaches to nothing and
                \\starts no runtime. Not one atomic snapshot: a pane removed meanwhile fails the
                \\listing rather than hiding. At most {d} panes.
                \\
                \\Results: text columns WORKSPACE, TAB, PANE, GENERATION, LIFECYCLE; JSON an array of
                \\`workspace_id`, `tab_id`, `position` (zero-based in the tab), `pane_id`,
                \\`pane_generation`, `lifecycle` (running|exited). Exit 0.
                \\
            , .{core.max_panes}),
            .examples = &.{ &.{ "pane", "list", "--json" }, &.{ "pane", "list", "--workspace", "4", "--tab", "9" } },
        },
        .{
            .name = "get",
            .summary = "Show one pane, agent or not, from the same topology",
            .usage = "telar pane get ID|--current [--workspace ID [--tab ID]] [--json] [--socket PATH]",
            .text =
            \\Arguments as `pane list`; an explicit --workspace and --tab avoid enumerating the
            \\whole runtime.
            \\
            \\Effects: read-only; needs a running runtime, never starts one.
            \\
            \\Results: one row without header, or one JSON object as `pane list` prints. Exit 0;
            \\2 with empty output when the pane does not exist.
            \\
            ,
            .examples = &.{ &.{ "pane", "get", "4", "--json" }, &.{ "pane", "get", "--current", "--workspace", "--current" } },
        },
        .{
            .name = "focus",
            .summary = "Focus a pane in a window; or, from Neovim, move focus out of this pane by direction",
            .usage = "telar pane focus ID --client ID [--json] [--socket PATH]\n       telar pane focus --current --direction left|right|up|down [--json] [--socket PATH]",
            .routed = &.{.pane_focus},
            .text = std.fmt.comptimePrint(
                \\Two forms. `pane focus ID --client ID` focuses that pane in the window's active tab;
                \\an already focused pane is a no-op. {s}
                \\
                \\`pane focus --current --direction D` is for an editor inside this pane that reached
                \\its own edge: the runtime asks the window that last typed into this pane to move
                \\focus one pane in that direction. Results: nothing, or JSON `changed`,
                \\`focused_pane_id`, `reason` (focused|no_neighbor|source_not_focused); exit 0 for
                \\every outcome, 1 when no window typed here, 2 when the pane is gone.
                \\
            , .{routed_text}),
            .examples = &.{ &.{ "pane", "focus", "4", "--client", "1" }, &.{ "pane", "focus", "--current", "--direction", "left", "--json" } },
        },
        .{
            .name = "create",
            .summary = "Create a terminal pane in a window by splitting its focused pane",
            .usage = "telar pane create --client ID [--json] [--socket PATH]",
            .routed = &.{.pane_create},
            .text = std.fmt.comptimePrint(
                \\{s}
                \\
                \\The window splits its focused pane left/right with its launch settings. The new
                \\pane is confirmed asynchronously (`admitted`) and takes the focus, so text to it
                \\is refused while a person looks; for a pane of your own use `tab create
                \\--background`.
                \\
            , .{routed_text}),
            .examples = &.{&.{ "pane", "create", "--client", "1", "--json" }},
        },
        .{
            .name = "split",
            .summary = "Focus a pane in a window and split it horizontally (left/right) or vertically (top/bottom)",
            .usage = "telar pane split ID horizontal|vertical --client ID [--json] [--socket PATH]",
            .routed = &.{.pane_split},
            .text = std.fmt.comptimePrint(
                \\{s}
                \\
                \\The focus moves to ID first and stays there even when the split is then refused
                \\for lack of room. The new pane is confirmed asynchronously (`admitted`).
                \\
            , .{routed_text}),
            .examples = &.{&.{ "pane", "split", "4", "horizontal", "--client", "1" }},
        },
        .{
            .name = "close",
            .summary = "Focus a pane in a window and request its closure",
            .usage = "telar pane close ID --client ID [--json] [--socket PATH]",
            .routed = &.{.pane_close},
            .text = std.fmt.comptimePrint(
                \\{s}
                \\
                \\The focus moves to ID first. `admitted` means the close is queued; the pane's exit
                \\is the runtime's to confirm (`pane get` reports it gone). To close a pane no
                \\window shows, close its tab with `telar tab close`.
                \\
            , .{routed_text}),
            .examples = &.{&.{ "pane", "close", "4", "--client", "1" }},
        },
        .{
            .name = "resize",
            .summary = "Focus a pane and move its nearest split edge one step in a direction",
            .usage = "telar pane resize ID left|right|up|down --client ID [--json] [--socket PATH]",
            .routed = &.{.pane_resize},
            .text = std.fmt.comptimePrint(
                \\{s}
                \\
                \\Uses the window's resize step. A pane with no split edge that way is refused.
                \\
            , .{routed_text}),
            .examples = &.{&.{ "pane", "resize", "4", "left", "--client", "1" }},
        },
        .{
            .name = "fullscreen",
            .summary = "Focus a pane and toggle it fullscreen in its window",
            .usage = "telar pane fullscreen ID --client ID [--json] [--socket PATH]",
            .routed = &.{.pane_fullscreen},
            .text = std.fmt.comptimePrint(
                \\{s}
                \\
                \\`value` is 1 when the pane is now fullscreen and 0 when it is tiled again.
                \\
            , .{routed_text}),
            .examples = &.{&.{ "pane", "fullscreen", "4", "--client", "1", "--json" }},
        },
        .{
            .name = "scroll",
            .summary = "Scroll a pane's viewport in a window by a signed number of rows",
            .usage = "telar pane scroll ID DELTA --client ID [--json] [--socket PATH]",
            .routed = &.{.pane_scroll},
            .text = std.fmt.comptimePrint(
                \\{s}
                \\
                \\DELTA is a signed row count. Changes only that window's scroll offset: no focus
                \\change, no keystrokes. Hitting the end is a successful no-op; a pane in copy
                \\mode or not attached is refused.
                \\
            , .{routed_text}),
            .examples = &.{&.{ "pane", "scroll", "4", "-20", "--client", "1" }},
        },
        .{
            .name = "copy",
            .summary = "Copy a range of a pane's text to a window's clipboard",
            .usage = "telar pane copy ID X1,Y1:X2,Y2 --client ID [--json] [--socket PATH]",
            .routed = &.{.pane_copy},
            .text = std.fmt.comptimePrint(
                \\{s}
                \\
                \\The range is inclusive, in absolute history coordinates as `pane search` prints
                \\them (column, row). `admitted` means the runtime extracts the text and the host
                \\receives it asynchronously. For your own text use `client clipboard copy`.
                \\
            , .{routed_text}),
            .examples = &.{&.{ "pane", "copy", "4", "0,10:79,12", "--client", "1" }},
        },
    },
};
