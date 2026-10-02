//! `telar worktree --help` and the help of its commands.

const std = @import("std");
const core = @import("telar-core");
const FamilyHelp = @import("../FamilyHelp.zig");
const WorktreeOptions = @import("../arguments/WorktreeOptions.zig");
const workspace_grammar = @import("../arguments/workspace.zig");
const values = @import("../arguments/values.zig");
const backend = @import("telar-backend");
const worktree = @import("../worktree.zig");

pub const family: FamilyHelp = .{
    .summary = "Git worktrees as tasks: create one for an agent, run commands in it, inspect and remove it",
    .usage = "telar worktree COMMAND [BRANCH|TITLE] [options] [-- COMMAND...]",
    .text =
    \\A worktree is a Git linked worktree the runtime tracks as the place a task
    \\happens. It belongs to one repository, hangs from that repository's
    \\workspace, and gets a child workspace of its own for its tabs. Every
    \\worktree the runtime tracks has a branch and may have a title (the task's
    \\name); commands on an existing worktree take either. A branch resolves
    \\exactly, a title case-insensitively, and a reference that fits two
    \\worktrees is refused (name it by the other one). `--json` and `--socket
    \\PATH` are accepted by every command.
    \\
    \\Pane, tab and workspace ids in replies belong to the runtime that answered.
    \\With `telar --machine LABEL worktree ...` they belong to that machine.
    \\
    ,
    .commands = &.{
        .{
            .name = "create",
            .summary = "Add a git worktree for a task; with a command (needs --title), run an agent there",
            .usage = "telar worktree create BRANCH [--title TITLE] [--from BASE] [--directory ABS] [--label TEXT] [--workspace ID|DIR] [--machine LABEL] [--setup] [--json] [--socket PATH] [-- COMMAND...]",
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  BRANCH           The branch Git creates (or checks out, when it exists); at most {d} bytes,
                \\                   no leading `-` or `.`, no `..`, spaces or control bytes.
                \\  --title TITLE    The task's name, how the user and `worktree list` refer to it; at most
                \\                   {d} bytes. Required when a command follows `--`.
                \\  --from BASE      Branch or ref the new branch starts from (default: the main checkout's
                \\                   current branch). Ignored when BRANCH already exists.
                \\  --directory ABS  Checkout directory (default: <repo parent>/<repo>-worktrees/<branch>,
                \\                   with `/` in the branch replaced by `-`). Not with --machine.
                \\  --label TEXT     Label of the tab the command runs in; at most {d} bytes.
                \\  --workspace X    The repository: a workspace id or a directory inside it (default: the
                \\                   pane's TELAR_WORKSPACE_ID, else the current directory).
                \\  --machine LABEL  Create the worktree on that saved machine (see below).
                \\  --setup          Authorize the repository's `.telar/setup.json` recipe to run first.
                \\  -- COMMAND...    What to run in the worktree, usually an agent and its brief; at most
                \\                   {d} words, taken literally. The agent sees nothing else.
                \\
                \\Effects: runs Git in the repository (`git worktree add`), registers the worktree with
                \\the runtime, creates the repository's workspace when none exists, runs project setup
                \\when a recipe is declared and --setup was given, then launches COMMAND (or a login
                \\shell) in a new {d}x{d} pane of the worktree's own workspace. Nothing attaches a
                \\window to that pane and no focus changes. Starts the local runtime when none runs.
                \\A declared recipe without --setup refuses the launch; the checkout and its row stay.
                \\At most {d} worktrees are tracked. Needs Git on PATH.
                \\
                \\With --machine LABEL: the branch's commits (BRANCH if it exists locally, else BASE,
                \\else HEAD) are prepared on that machine (`telar repository prepare`), pushed into its
                \\clone, and `worktree create` runs there. Only commits travel; uncommitted files stay
                \\here and are counted on stderr. The ids in the reply are that machine's.
                \\
                \\Results: text `worktree BRANCH at PATH: pane N in workspace N`; JSON `worktree_id`,
                \\`setup_execution_id`, `environment` (`ready`|`not_declared`), `branch`, `base`,
                \\`path`, `workspace_id`, `tab_id`, `pane_id`, `pane_generation`. Exit 0; 1 on a Git,
                \\setup or runtime refusal (the reason on stderr).
                \\
            , .{ workspace_grammar.max_worktree_branch_bytes, core.max_worktree_title_bytes, core.max_tab_label_bytes, WorktreeOptions.max_command_arguments, worktree.launch_size.cols, worktree.launch_size.rows, core.max_worktree_entries }),
            .examples = &.{
                &.{ "worktree", "create", "fix-tab-order" },
                &.{ "worktree", "create", "fix-tab-order", "--title", "Fix tab order", "--json", "--", "claude", "Fix the tab order; run the tests." },
                &.{ "worktree", "create", "fix-tab-order", "--machine", "box", "--from", "main", "--title", "Fix tab order", "--setup", "--", "codex", "--no-daemon", "Read the brief." },
            },
        },
        .{
            .name = "exec",
            .summary = "Run a command in a new tab of a worktree; --wait prints output and returns its exit status",
            .usage = "telar worktree exec BRANCH|TITLE [--label TEXT] [--wait [--timeout SECONDS]] [--json] [--socket PATH] -- COMMAND...",
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  BRANCH|TITLE     A tracked worktree, or an untracked linked worktree of the current
                \\                   directory's repository, which gets registered first.
                \\  --label TEXT     Tab label; at most {d} bytes.
                \\  --wait           Block until COMMAND exits, then print what its terminal showed.
                \\  --timeout S      With --wait: give up after S seconds (default {d}, up to {d}); `s`
                \\                   suffix accepted. The command keeps running after a timeout.
                \\  -- COMMAND...    Required; at most {d} words, run through the login shell
                \\                   (`$SHELL -l -i -c 'exec "$0" "$@"' COMMAND...`).
                \\
                \\Effects: opens a new tab or pane in the worktree's workspace and runs COMMAND there,
                \\in a terminal. No window attaches and no focus changes. Starts the local runtime
                \\when none runs. This is a terminal: stdout and stderr are merged into screen text,
                \\and the shell's rc files may print first. For raw byte streams and a literal argv
                \\without a shell, use `telar exec`.
                \\
                \\Results without --wait: the launch line or JSON of `worktree create`, exit 0.
                \\With --wait: the pane's text is printed once the command has exited, trailing blank
                \\rows trimmed, and the exit status is the command's own (signals as 128+n). JSON:
                \\`pane_id`, `exit_code`, `truncated`, `output`. A finished pane keeps its last {d}
                \\rows within {d} KiB; `truncated` (and a stderr note) means it printed more. Only
                \\the last {d} finished panes are kept, so read promptly. Timeout: stderr names the
                \\pane still running, exit 3.
                \\
            , .{ core.max_tab_label_bytes, WorktreeOptions.default_wait_seconds, values.max_wait_timeout_seconds, WorktreeOptions.max_command_arguments, backend.ExitedPanes.kept_rows, backend.ExitedPanes.max_text_bytes / 1024, backend.ExitedPanes.capacity }),
            .examples = &.{
                &.{ "worktree", "exec", "fix-tab-order", "--label", "tests", "--", "zig", "build", "test" },
                &.{ "worktree", "exec", "Fix tab order", "--wait", "--timeout", "900s", "--json", "--", "npm", "test" },
            },
        },
        .{
            .name = "list",
            .summary = "List worktrees with their task, state, agent, diffstat and last command",
            .usage = "telar worktree list [--workspace ID|DIR] [--json] [--socket PATH]",
            .text =
            \\Arguments:
            \\  --workspace X    Only the worktrees of that repository (a workspace id or directory).
            \\
            \\Effects: reads the runtime's worktree catalog and agents, then `git worktree list` in
            \\the current directory's repository, so linked worktrees telar does not track appear
            \\as `untracked`. Read-only; starts the local runtime when none runs.
            \\
            \\Results: text columns BRANCH, TITLE, STATE (active|integrated|gone), AGENT (the first
            \\agent's status), DIFF (+added -removed N files), COMMAND (label and none|running|
            \\exited), PATH. JSON: an array of `worktree_id`, `branch`, `title`, `brief`, `base`,
            \\`dispatched_from`, `coordinator`, `path`, `origin` (telar|external), `state`,
            \\`source_workspace_id`, `workspace_id`, `diff` {added, removed, files, commits_ahead},
            \\`command` {label, state, exit_code} and `agents` (as `telar agent list --json`).
            \\Match the user's words against `title`, `brief` and `branch`. Exit 0.
            \\
            ,
            .examples = &.{
                &.{ "worktree", "list", "--json" },
                &.{ "worktree", "list", "--workspace", "4" },
            },
        },
        .{
            .name = "open",
            .summary = "Show a worktree's workspace in a window: the one used last, or --client",
            .usage = "telar worktree open BRANCH|TITLE [--client ID] [--json] [--socket PATH]",
            .text =
            \\Arguments:
            \\  --client ID      The window to switch (default: the one a person typed in last).
            \\
            \\Effects: changes which workspace that window shows by sending `workspace select`. The
            \\worktree must be tracked and have a workspace. Starts the local runtime when none runs.
            \\
            \\Results: `opened BRANCH in client N`; JSON `worktree_id`, `workspace_id`, `client_id`.
            \\Exit 0; 2 when the worktree or its workspace is unknown; 1 when no window is attached.
            \\
            ,
            .examples = &.{
                &.{ "worktree", "open", "fix-tab-order" },
                &.{ "worktree", "open", "Fix tab order", "--client", "3", "--json" },
            },
        },
        .{
            .name = "diff",
            .summary = "Print the worktree's diff against its base, or its uncommitted changes",
            .usage = "telar worktree diff BRANCH|TITLE [--stat] [--uncommitted] [--socket PATH]",
            .text =
            \\Arguments:
            \\  --stat           Only the diffstat.
            \\  --uncommitted    Changes not yet committed (against HEAD) instead of the branch's work.
            \\
            \\Effects: runs `git diff` in the worktree, against the merge base of its base and HEAD
            \\by default. Read-only for Git; an untracked linked worktree of the current repository
            \\gets registered first. Starts the local runtime when none runs.
            \\
            \\Results: the diff on stdout, as Git prints it. Exit 0; 1 when Git fails. Answer
            \\questions about a task from this diff, not from its pane's screen.
            \\
            ,
            .examples = &.{
                &.{ "worktree", "diff", "fix-tab-order", "--stat" },
                &.{ "worktree", "diff", "Fix tab order", "--uncommitted" },
            },
        },
        .{
            .name = "remove",
            .summary = "Close a worktree's tabs and remove its checkout; refused with uncommitted changes",
            .usage = "telar worktree remove BRANCH|TITLE [--force] [--delete-branch] [--json] [--socket PATH]",
            .text =
            \\Arguments:
            \\  --force          Remove despite uncommitted or untracked files. Asks `[y/N]` on the
            \\                   terminal; without one it fails, so a person must run it.
            \\  --delete-branch  Also delete the branch. Merged into its upstream (or HEAD): deleted
            \\                   without asking. Otherwise it asks on the terminal, like --force.
            \\
            \\Effects: tells the runtime to forget the worktree, which closes the panes of its
            \\workspace, then runs `git worktree remove`. Only tracked worktrees. A checkout that
            \\is already gone is only forgotten. Starts the local runtime when none runs.
            \\
            \\Results: `removed BRANCH at PATH`; JSON `worktree_id`, `path`, `branch_deleted`.
            \\Exit 0; 1 when refused (changes present, no terminal to confirm, Git failed).
            \\
            ,
            .examples = &.{
                &.{ "worktree", "remove", "fix-tab-order" },
                &.{ "worktree", "remove", "fix-tab-order", "--delete-branch", "--json" },
            },
        },
        .{
            .name = "fetch",
            .summary = "Bring a branch back from another machine into refs/remotes/LABEL/BRANCH",
            .usage = "telar worktree fetch BRANCH --machine LABEL [--json]",
            .text =
            \\Arguments:
            \\  BRANCH           The branch on that machine.
            \\  --machine LABEL  Required: a saved machine other than this one.
            \\
            \\Effects: asks the machine where this repository's clone is (`worktree resolve` there),
            \\then `git fetch` over SSH into `refs/remotes/LABEL/BRANCH`. Touches no local runtime
            \\and no local branch; review or merge the ref yourself afterwards.
            \\
            \\Results: `fetched BRANCH from LABEL into REF at COMMIT`; JSON `machine`, `branch`,
            \\`ref`, `commit`. Exit 0; 1 on failure (Git's words on stderr).
            \\
            ,
            .examples = &.{
                &.{ "worktree", "fetch", "fix-tab-order", "--machine", "box", "--json" },
            },
        },
        .{
            .name = "resolve",
            .summary = "Find the clone of a repository among this machine's workspaces",
            .usage = "telar worktree resolve --repository IDENTITY [--workspace PATH|ID] [--json] [--socket PATH]",
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  --repository X   The repository identity: its origin URL as host/path, without
                \\                   userinfo or default port; at most {d} bytes.
                \\  --workspace X    Choose among several clones by path or workspace id.
                \\
                \\Effects: searches the runtime's workspaces and worktrees, then the history database,
                \\then the managed clones under $XDG_DATA_HOME/telar/repositories. Read-only; starts
                \\the local runtime when none runs. `worktree fetch` and remote `worktree create` run
                \\it on the other machine for you.
                \\
                \\Results: the clone's path; JSON `repository`, `path`. Exit 0; 1 when none or several
                \\match (name one with --workspace).
                \\
            , .{WorktreeOptions.max_repository_bytes}),
            .examples = &.{
                &.{ "worktree", "resolve", "--repository", "github.com/adriangs1996/telar", "--json" },
            },
        },
    },
};
