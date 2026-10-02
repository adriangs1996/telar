//! `telar layout --help` and the help of its commands.

const FamilyHelp = @import("../FamilyHelp.zig");

pub const family: FamilyHelp = .{
    .summary = "Export a window's active tab layout as a token and apply it back",
    .usage = "telar layout get|apply [TOKEN] --client ID [--json] [--socket PATH]",
    .text =
    \\The layout is the window's: the split tree, pane surfaces, focused pane and fullscreen
    \\state of its active tab, plus the sidebar and workspace list preferences. The token is
    \\hexadecimal in telar's validated layout schema with stable runtime ids, meant for
    \\`layout apply` on the same live tab with the same panes. Needs a running runtime;
    \\never starts one. Exit codes: 0; 1 when the window refused; 2 unknown client; 3 no
    \\answer in time.
    \\
    ,
    .commands = &.{
        .{
            .name = "get",
            .summary = "Print the active tab's layout token",
            .usage = "telar layout get --client ID [--json] [--socket PATH]",
            .routed = &.{.layout_get},
            .text =
            \\Effects: read-only on the window. Results: the token; JSON `encoding`
            \\(`telar-layout-hex`) and `data`. Refused without an active tab or focused pane.
            \\
            ,
            .examples = &.{&.{ "layout", "get", "--client", "1", "--json" }},
        },
        .{
            .name = "apply",
            .summary = "Restore a layout token on the active tab",
            .usage = "telar layout apply TOKEN --client ID [--json] [--socket PATH]",
            .routed = &.{.layout_apply},
            .text =
            \\Effects: the window checks the token names its active tab and exactly its panes,
            \\then restores the split tree, surfaces, focus and fullscreen state and resizes
            \\the runtime's panes. Refused for another tab, a changed pane set, an invalid tree
            \\or while another request is in flight. Results: text `layout_apply: applied` or
            \\the JSON of every routed command.
            \\
            ,
            .examples = &.{&.{ "layout", "apply", "0a0b0c", "--client", "1" }},
        },
    },
};
