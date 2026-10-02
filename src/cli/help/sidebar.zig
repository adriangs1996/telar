//! `telar sidebar --help` and the help of its commands.

const std = @import("std");
const FamilyHelp = @import("../FamilyHelp.zig");

const routed_text =
    \\Effects: forwarded to the window `--client ID` names; the window commits the change
    \\and resizes its panes. Needs a running runtime; never starts one. Results: text
    \\`ACTION: STATUS visible|hidden` with `value` the committed width, or JSON
    \\`client_id`, `client_generation`, `action`, `status`, `target_id`, `value`, `text`.
    \\Exit 0; 1 when the window refused; 2 unknown client; 3 no answer in time.
;

pub const family: FamilyHelp = .{
    .summary = "Show, hide, resize and read a window's sidebar",
    .usage = "telar sidebar get|show|hide|resize [COLUMNS] --client ID [--json] [--socket PATH]",
    .text =
    \\Visibility and the column width below belong to the shared client model. The native
    \\window uses a separate pixel width from `gui.sidebar.width`, its resize keys and
    \\edge dragging. `resize` changes the shared column preference, not that native
    \\width; `get` reports the column preference. Hiding the native sidebar leaves a
    \\narrow workspace rail when space permits.
    \\
    ,
    .commands = &.{
        .{
            .name = "get",
            .summary = "Report whether the sidebar is visible and its width",
            .usage = "telar sidebar get --client ID [--json] [--socket PATH]",
            .routed = &.{.sidebar_get},
            .text =
            \\Effects: read-only on the window. Results: `visible|hidden N columns`; JSON
            \\`visible`, `width`. Exit 0; 2 unknown client; 3 no answer in time.
            \\
            ,
            .examples = &.{&.{ "sidebar", "get", "--client", "1", "--json" }},
        },
        .{
            .name = "show",
            .summary = "Show the sidebar (idempotent)",
            .usage = "telar sidebar show --client ID [--json] [--socket PATH]",
            .routed = &.{.sidebar_show},
            .text = routed_text ++ "\n",
            .examples = &.{&.{ "sidebar", "show", "--client", "1" }},
        },
        .{
            .name = "hide",
            .summary = "Hide the sidebar (idempotent)",
            .usage = "telar sidebar hide --client ID [--json] [--socket PATH]",
            .routed = &.{.sidebar_hide},
            .text = routed_text ++ "\n",
            .examples = &.{&.{ "sidebar", "hide", "--client", "1" }},
        },
        .{
            .name = "resize",
            .summary = "Set the shared client's sidebar column preference; native pixel width is separate",
            .usage = "telar sidebar resize COLUMNS --client ID [--json] [--socket PATH]",
            .routed = &.{.sidebar_resize},
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  COLUMNS          A positive width; the window clamps it to its minimum and its
                \\                   own width, and `value` reports what it committed.
                \\                   The native window uses gui.sidebar.width instead of this value.
                \\
                \\{s}
                \\
            , .{routed_text}),
            .examples = &.{&.{ "sidebar", "resize", "40", "--client", "1", "--json" }},
        },
    },
};
