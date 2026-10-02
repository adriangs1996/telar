//! `telar notification --help` and the help of its commands.

const std = @import("std");
const core = @import("telar-core");
const FamilyHelp = @import("../FamilyHelp.zig");

pub const family: FamilyHelp = .{
    .summary = "Show a toast in every attached window, or dismiss one in a window",
    .usage = "telar notification show TITLE [options] | telar notification dismiss ID --client ID",
    .commands = &.{
        .{
            .name = "show",
            .summary = "Show a toast in every attached window, optionally clickable",
            .usage = "telar notification show TITLE [--body TEXT] [--level info|success|warning|failure] [--duration MS] [--pane ID | --tab ID | --workspace ID] [--link URL] [--socket PATH]",
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  TITLE            At most {d} bytes, no control characters.
                \\  --body TEXT      Detail below the title; at most {d} bytes.
                \\  --level LEVEL    `info` (default), `success`, `warning` or `failure`.
                \\  --duration MS    Visible for {d} to {d} ms (default {d}).
                \\  --pane, --tab, --workspace ID  One click target: focus that pane, select that
                \\                   tab or workspace.
                \\  --link URL       An https URL a click opens in the browser; at most {d} bytes.
                \\
                \\Effects: the runtime delivers the toast to every attached window. Needs a running
                \\runtime; never starts one.
                \\
                \\Results: nothing; exit 0. Exit 1 when the runtime is not running, no window is
                \\attached, or the text is too long or invalid.
                \\
            , .{ core.max_notification_title_bytes, core.max_notification_message_bytes, core.min_notification_duration_ms, core.max_notification_duration_ms, core.default_notification_duration_ms, core.max_notification_link_bytes }),
            .examples = &.{ &.{ "notification", "show", "Build complete", "--body", "Open the pane", "--level", "success", "--duration", "2500", "--pane", "42" }, &.{ "notification", "show", "Review ready", "--link", "https://example.com/pr/1" } },
        },
        .{
            .name = "dismiss",
            .summary = "Dismiss one notification shown in a window",
            .usage = "telar notification dismiss ID --client ID [--json] [--socket PATH]",
            .routed = &.{.notification_dismiss},
            .text =
            \\Effects: forwarded to the window `--client ID` names, which dismisses the
            \\notification with that id and rearms its timer. Needs a running runtime; never
            \\starts one. Results: text `notification_dismiss: applied` or the JSON of every
            \\routed command. Exit 0; 1 when the id is unknown there; 2 unknown client; 3 no
            \\answer in time.
            \\
            ,
            .examples = &.{&.{ "notification", "dismiss", "5", "--client", "1" }},
        },
    },
};
