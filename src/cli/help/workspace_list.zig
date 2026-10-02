//! `telar workspace-list --help` and the help of its commands.

const FamilyHelp = @import("../FamilyHelp.zig");

const routed_text =
    \\Effects: forwarded to the window `--client ID` names, which commits the state in its
    \\model and chrome. Idempotent. Needs a running runtime; never starts one. Results:
    \\text `ACTION: applied` or JSON `client_id`, `client_generation`, `action`, `status`,
    \\`target_id`, `value`, `text`. Exit 0; 2 unknown client; 3 no answer in time.
    \\
;

pub const family: FamilyHelp = .{
    .summary = "Expand or collapse the workspace list of a window",
    .usage = "telar workspace-list expand|collapse --client ID [--json] [--socket PATH]",
    .text =
    \\The workspace list is part of one window's chrome; the runtime keeps no such state.
    \\
    ,
    .commands = &.{
        .{
            .name = "expand",
            .summary = "Expand the workspace list",
            .usage = "telar workspace-list expand --client ID [--json] [--socket PATH]",
            .routed = &.{.workspace_list_expand},
            .text = routed_text,
            .examples = &.{&.{ "workspace-list", "expand", "--client", "1" }},
        },
        .{
            .name = "collapse",
            .summary = "Collapse the workspace list",
            .usage = "telar workspace-list collapse --client ID [--json] [--socket PATH]",
            .routed = &.{.workspace_list_collapse},
            .text = routed_text,
            .examples = &.{&.{ "workspace-list", "collapse", "--client", "1", "--json" }},
        },
    },
};
