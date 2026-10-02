//! `telar tab --help` and the help of its commands.

const std = @import("std");
const core = @import("telar-core");
const FamilyHelp = @import("../FamilyHelp.zig");
const tab = @import("../tab.zig");

const routed_text =
    \\Effects: forwarded to the window `--client ID` names (see `telar client list`), in
    \\its current workspace. Needs a running runtime; never starts one. Results: text
    \\`ACTION: STATUS` or JSON `client_id`, `client_generation`, `action`, `status`,
    \\`target_id`, `value`, `text`. `applied` means done; `admitted` means the window
    \\queued it and the runtime confirms later. Exit 0; 1 when the window refused; 2
    \\unknown client; 3 no answer in time.
;

pub const family: FamilyHelp = .{
    .summary = "List, open, rename, move and close the tabs of a workspace; select them in a window",
    .usage = "telar tab COMMAND [ID|--current] [--workspace ID|--current] [options]",
    .text =
    \\A tab belongs to one workspace and holds one or more panes. Ids are stable; a tab's
    \\position is zero-based and changes when tabs move. `--workspace` defaults to
    \\`--current` (TELAR_WORKSPACE_ID); a tab `--current` is TELAR_TAB_ID. `list`, `get`,
    \\`rename`, `close`, `move` and `create --background` act on the runtime; attached
    \\windows reflect those changes. `create --client`, `select`, `next` and `previous` act on one window's
    \\selection. Exit codes: 0; 1 when refused (the runtime's reason on stderr, such as
    \\`tab not found`); 3 when the runtime did not answer in time.
    \\
    ,
    .commands = &.{
        .{
            .name = "list",
            .summary = "List a workspace's tabs with id, position, pane count and label",
            .usage = "telar tab list [--workspace ID|--current] [--json] [--socket PATH]",
            .text =
            \\Effects: reads the workspace snapshot; attaches nothing, starts no runtime.
            \\
            \\Results: text columns ID, POSITION, PANES, LABEL in runtime order; JSON an array of
            \\`workspace_id`, `tab_id`, `position`, `pane_count`, `label`. Exit 0.
            \\
            ,
            .examples = &.{ &.{ "tab", "list", "--workspace", "4", "--json" }, &.{ "tab", "list" } },
        },
        .{
            .name = "get",
            .summary = "Show a tab's panes with their generations and lifecycle",
            .usage = "telar tab get ID|--current [--workspace ID|--current] [--json] [--socket PATH]",
            .text =
            \\Effects: reads the tab snapshot; takes no geometry lease, attaches nothing, starts
            \\no runtime.
            \\
            \\Results: text columns PANE, GENERATION, LIFECYCLE; JSON `workspace_id`, `tab_id`,
            \\`panes` (pane_id, pane_generation, lifecycle running|exited). Exit 0; 1 when the tab
            \\or workspace is unknown.
            \\
            ,
            .examples = &.{&.{ "tab", "get", "9", "--workspace", "4", "--json" }},
        },
        .{
            .name = "create",
            .summary = "Open a tab: --background runs a shell no window shows; --client adds one to a window",
            .usage = "telar tab create --background [--workspace ID|--current] [--label TEXT] [--json] [--socket PATH]\n       telar tab create --client ID [--label TEXT] [--json] [--socket PATH]",
            .routed = &.{.tab_create},
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  --background     Ask the runtime, not a window: the tab opens in the workspace's
                \\                   directory with the login shell in a {d}x{d} pane, no window
                \\                   attaches and no focus changes, so `pane send-keys` can type
                \\                   there at once. This is the tab for automation.
                \\  --client ID      Ask that window instead: it creates the tab with its own launch
                \\                   settings and moves its focus there (`admitted`; the runtime
                \\                   confirms the tab asynchronously).
                \\  --label TEXT     At most {d} bytes of UTF-8.
                \\
                \\Results with --background: `tab T opened in workspace W: pane P`; JSON
                \\`workspace_id`, `tab_id`, `pane_id`, `pane_generation`. At most {d} tabs per
                \\workspace. Exit 0; 1 when the workspace is unknown or full. With --client: {s}
                \\
            , .{ tab.background_size.cols, tab.background_size.rows, core.max_tab_label_bytes, core.max_tabs_per_workspace, routed_text }),
            .examples = &.{ &.{ "tab", "create", "--background", "--workspace", "4", "--label", "tests", "--json" }, &.{ "tab", "create", "--client", "1", "--label", "scratch" } },
        },
        .{
            .name = "rename",
            .summary = "Rename a tab",
            .usage = "telar tab rename ID|--current LABEL [--workspace ID|--current] [--json] [--socket PATH]",
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  LABEL            1 to {d} bytes of UTF-8.
                \\
                \\Effects: the runtime renames the tab and every window follows. Never starts one.
                \\
                \\Results: `tab N renamed to LABEL`, the label as the runtime kept it; JSON
                \\`workspace_id`, `tab_id`, `label`. Exit 0; 1 when refused.
                \\
            , .{core.max_tab_label_bytes}),
            .examples = &.{&.{ "tab", "rename", "9", "tests", "--workspace", "4" }},
        },
        .{
            .name = "close",
            .summary = "Close a tab and the panes in it; the last tab closes its workspace",
            .usage = "telar tab close ID|--current [--workspace ID|--current] [--json] [--socket PATH]",
            .text =
            \\Effects: the runtime closes the tab's panes and removes the tab; a workspace left
            \\without tabs disappears too. Never starts a runtime.
            \\
            \\Results: `tab N closed`; JSON `workspace_id`, `tab_id`, `closed`, `workspace_closed`.
            \\Exit 0; 1 when the tab is unknown.
            \\
            ,
            .examples = &.{&.{ "tab", "close", "9", "--workspace", "4", "--json" }},
        },
        .{
            .name = "move",
            .summary = "Move a tab one position, or before/after another tab",
            .usage = "telar tab move ID|--current previous|next [--relative-to ID] [--workspace ID|--current] [--json] [--socket PATH]",
            .text =
            \\Arguments:
            \\  previous|next    Without --relative-to: one position left or right (an edge is a
            \\                   successful no-op). With it: before or after that tab.
            \\  --relative-to ID A tab id of the same workspace (not --current).
            \\
            \\Effects: reorders the workspace's tabs in the runtime. Never starts one.
            \\
            \\Results: `tab N moved to position P` (zero-based); JSON `workspace_id`, `tab_id`,
            \\`position`. Exit 0; 1 when refused.
            \\
            ,
            .examples = &.{&.{ "tab", "move", "9", "next", "--relative-to", "3", "--workspace", "4" }},
        },
        .{
            .name = "select",
            .summary = "Select a tab in a window's current workspace",
            .usage = "telar tab select ID --client ID [--json] [--socket PATH]",
            .routed = &.{.tab_select},
            .text = std.fmt.comptimePrint(
                \\{s}
                \\
                \\An already selected tab answers `applied`; a change answers `admitted` while the
                \\window attaches the tab's panes.
                \\
            , .{routed_text}),
            .examples = &.{&.{ "tab", "select", "9", "--client", "1" }},
        },
        .{
            .name = "next",
            .summary = "Select the next tab in a window, cyclically",
            .usage = "telar tab next --client ID [--json] [--socket PATH]",
            .routed = &.{.tab_next},
            .text = std.fmt.comptimePrint(
                \\{s}
                \\
                \\A single tab is a successful no-op (`applied`).
                \\
            , .{routed_text}),
            .examples = &.{&.{ "tab", "next", "--client", "1" }},
        },
        .{
            .name = "previous",
            .summary = "Select the previous tab in a window, cyclically",
            .usage = "telar tab previous --client ID [--json] [--socket PATH]",
            .routed = &.{.tab_previous},
            .text = std.fmt.comptimePrint(
                \\{s}
                \\
                \\A single tab is a successful no-op (`applied`).
                \\
            , .{routed_text}),
            .examples = &.{&.{ "tab", "previous", "--client", "1", "--json" }},
        },
    },
};
