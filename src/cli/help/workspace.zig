//! `telar workspace --help` and the help of its commands.

const std = @import("std");
const core = @import("telar-core");
const FamilyHelp = @import("../FamilyHelp.zig");
const WorkspaceOptions = @import("../arguments/WorkspaceOptions.zig");

pub const family: FamilyHelp = .{
    .summary = "Create, list, rename and show workspaces: a directory and its ordered tabs",
    .usage = "telar workspace COMMAND [ID|--current] [options]",
    .text = std.fmt.comptimePrint(
        \\A workspace is a directory the runtime holds tabs for. Its id is stable; `--current`
        \\is TELAR_WORKSPACE_ID. `create`, `list`, `get` and `rename` act on the runtime;
        \\windows reflect workspace additions and renames. `select` switches one window's
        \\active workspace. At most {d} workspaces.
        \\Exit codes: 0, or 1 with the reason on stderr.
        \\
    , .{core.max_workspace_list_entries}),
    .commands = &.{
        .{
            .name = "create",
            .summary = "Open a workspace on a directory, with a shell or a command in its first pane; or on a new worktree",
            .usage = "telar workspace create --directory DIR [--name NAME] [--columns N] [--json] [--socket PATH] [-- COMMAND...]\n       telar workspace create --worktree BRANCH [--name NAME] [--directory DIR]",
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  --directory DIR  An existing directory, resolved before anything connects.
                \\  --name NAME      The workspace's name (default: the directory's basename; at most
                \\                   {d} bytes).
                \\  --columns N      Width of the first pane until a window sizes it ({d} to {d},
                \\                   default {d}); rows start at 24. Wide enough, a login URL stays on
                \\                   one line for `pane read`.
                \\  -- COMMAND...    What the first pane runs instead of the login shell; at most {d}
                \\                   words, literal.
                \\  --worktree BRANCH  Instead: `telar worktree create BRANCH`, with --name as its
                \\                   title; no command or width here.
                \\
                \\Effects: the runtime creates the workspace, one tab and one pane running COMMAND
                \\or $SHELL. No window attaches and no focus changes. Starts the local runtime when
                \\none runs. Runs no Git without --worktree.
                \\
                \\Results: `workspace N created at DIR`; JSON `workspace_id`, `tab_id`, `pane_id`,
                \\`directory`, so you can close what you opened with `tab close`. Exit 0; 1 when
                \\refused (missing directory, full runtime).
                \\
            , .{ core.max_workspace_name_bytes, WorkspaceOptions.min_columns, WorkspaceOptions.max_columns, WorkspaceOptions.default_columns, core.max_argument_count }),
            .examples = &.{ &.{ "workspace", "create", "--directory", "/home/dev/project", "--json" }, &.{ "workspace", "create", "--directory", "/home/dev", "--columns", "200", "--", "codex", "login", "--device-auth" }, &.{ "workspace", "create", "--worktree", "fix-tab-order", "--name", "Fix tab order" } },
        },
        .{
            .name = "list",
            .summary = "List workspaces with id, name, directory, tab count, branch and dirty flag",
            .usage = "telar workspace list [--json] [--socket PATH]",
            .text =
            \\Effects: reads the runtime's workspace list once and disconnects; the Git columns are
            \\the runtime's retained probe, the CLI runs no Git. Needs a running runtime; never
            \\starts one.
            \\
            \\Results: text columns ID, NAME, DIRECTORY, TABS, BRANCH, GIT (dirty|clean); JSON an
            \\array (`[]` when empty) of `workspace_id`, `name`, `path`, `tab_count`, `branch`,
            \\`dirty`. Exit 0.
            \\
            ,
            .examples = &.{&.{ "workspace", "list", "--json" }},
        },
        .{
            .name = "get",
            .summary = "Show one workspace",
            .usage = "telar workspace get ID|--current [--json] [--socket PATH]",
            .text =
            \\Effects: as `workspace list`, selecting one entry. Never starts a runtime.
            \\
            \\Results: one row, or one JSON object as `workspace list` prints. Exit 0; 1 with no
            \\output when the workspace does not exist.
            \\
            ,
            .examples = &.{ &.{ "workspace", "get", "4", "--json" }, &.{ "workspace", "get", "--current" } },
        },
        .{
            .name = "rename",
            .summary = "Rename a workspace",
            .usage = "telar workspace rename ID|--current NAME [--json] [--socket PATH]",
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  NAME             1 to {d} bytes of UTF-8.
                \\
                \\Effects: the runtime renames the workspace and every window follows. Never starts
                \\one.
                \\
                \\Results: `workspace N renamed to NAME`, as the runtime kept it; JSON
                \\`workspace_id`, `name`. Exit 0; 1 when refused.
                \\
            , .{core.max_workspace_name_bytes}),
            .examples = &.{&.{ "workspace", "rename", "4", "telar", "--json" }},
        },
        .{
            .name = "select",
            .summary = "Show a workspace in a window",
            .usage = "telar workspace select ID --client ID [--json] [--socket PATH]",
            .routed = &.{.workspace_select},
            .text =
            \\Effects: forwarded to the window `--client ID` names (see `telar client list`),
            \\which switches to that workspace. The runtime keeps no window state. Needs a running
            \\runtime; never starts one.
            \\
            \\Results: text `workspace_select: STATUS` or JSON `client_id`, `client_generation`,
            \\`action`, `status`, `target_id`, `value`, `text`. `applied` when it already showed
            \\it; `admitted` while the handoff proceeds. Exit 0; 1 when the window refused
            \\(unknown workspace, busy); 2 unknown client; 3 no answer in time.
            \\
            ,
            .examples = &.{&.{ "workspace", "select", "4", "--client", "1", "--json" }},
        },
    },
};
