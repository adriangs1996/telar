//! `telar project --help` and the help of its commands.

const std = @import("std");
const FamilyHelp = @import("../FamilyHelp.zig");
const project_setup = @import("../project_setup.zig");

pub const family: FamilyHelp = .{
    .summary = "Run a repository's declared setup recipe in a checkout, explicitly authorized",
    .usage = "telar project setup --cwd ABS [--detach] [--json]",
    .commands = &.{
        .{
            .name = "setup",
            .summary = "Run `.telar/setup.json` of a checkout as a runtime execution and wait for it",
            .usage = "telar project setup --cwd ABS [--detach] [--json]",
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  --cwd ABS        The checkout; its `.telar/setup.json` declares
                \\                   `{{ "version": 1, "argv": ["program", "arg"] }}` (a user-owned
                \\                   regular file of at most {d} KiB).
                \\  --detach         Return once the execution started.
                \\
                \\Effects: starts the recipe as `telar exec` would, in that directory with stdin
                \\closed, and streams its output to stderr while waiting up to {d} s. Running this
                \\command is the authorization: `worktree create` runs it only with --setup. Every
                \\invocation runs the recipe again; nothing caches success. Starts the local runtime
                \\when none runs.
                \\
                \\Results: JSON `execution_id`, `environment` (not_declared|running|ready), `ready`.
                \\Exit 0; 1 when the recipe is invalid, exited nonzero, or the wait timed out (the
                \\setup goes on: inspect it with `exec status` and `exec output`).
                \\
            , .{ project_setup.max_recipe_bytes / 1024, project_setup.wait_seconds }),
            .examples = &.{ &.{ "project", "setup", "--cwd", "/home/dev/telar-worktrees/fix", "--json" }, &.{ "project", "setup", "--cwd", "/home/dev/project", "--detach" } },
        },
    },
};
