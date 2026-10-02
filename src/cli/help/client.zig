//! `telar client --help` and the help of its commands.

const std = @import("std");
const core = @import("telar-core");
const FamilyHelp = @import("../FamilyHelp.zig");

const routed_text =
    \\Effects: forwarded to the window `--client ID` names. Needs a running runtime; never
    \\starts one. Results: text `ACTION: STATUS` or JSON `client_id`, `client_generation`,
    \\`action`, `status`, `target_id`, `value`, `text`; `applied` means done, `admitted`
    \\means queued and completed asynchronously. Exit 0; 1 when the window refused; 2
    \\unknown client; 3 no answer in time.
;

pub const family: FamilyHelp = .{
    .summary = "List and detach attached windows; open their pickers, copy mode, links and clipboard",
    .usage = "telar client COMMAND [ID] [options]",
    .text = std.fmt.comptimePrint(
        \\A client is one attached window (or headless client) of the runtime: it owns its
        \\layout, focus, selection and scroll, all disposable; the runtime owns everything
        \\else. `client list` gives the ids that `--client ID` takes everywhere. A client id is
        \\paired with a generation so a reconnected window is never mistaken for the old one.
        \\At most {d} clients are listed. Exit codes: 0; 2 unknown client; 3 no answer in
        \\time; 1 anything else.
        \\
    , .{core.ClientList.capacity}),
    .commands = &.{
        .{
            .name = "list",
            .summary = "List the attached windows with id, generation, identity and last input pane",
            .usage = "telar client list [--json] [--socket PATH]",
            .text =
            \\Effects: read-only; needs a running runtime, never starts one.
            \\
            \\Results: text columns CLIENT, GENERATION, IDENTITY, ATTACHMENTS, LAST INPUT PANE;
            \\JSON an array of `id`, `generation`, `identity`, `attachments`, `last_input_pane`,
            \\`last_input_sequence`. The highest `last_input_sequence` is the window a person
            \\used last. Exit 0.
            \\
            ,
            .examples = &.{&.{ "client", "list", "--json" }},
        },
        .{
            .name = "get",
            .summary = "Show one attached window",
            .usage = "telar client get ID [--json] [--socket PATH]",
            .text =
            \\Effects: read-only; never starts a runtime.
            \\
            \\Results: one row or one JSON object as `client list` prints. Exit 0; 2 with no
            \\output when the client is not attached.
            \\
            ,
            .examples = &.{&.{ "client", "get", "1", "--json" }},
        },
        .{
            .name = "detach",
            .summary = "Disconnect a window from the runtime; its panes keep running",
            .usage = "telar client detach ID [--json] [--socket PATH]",
            .text =
            \\Effects: the runtime drops that window's connection at its exact generation,
            \\releasing its attachments and geometry; every pane, agent and command stays alive
            \\and a window can reconnect. Never starts a runtime.
            \\
            \\Results: `client N detached`; JSON `id`, `generation`, `detached`. Exit 0; 2 when
            \\unknown; 1 when refused (a stale generation, a non-window client).
            \\
            ,
            .examples = &.{&.{ "client", "detach", "1" }},
        },
        .{
            .name = "open",
            .summary = "Open the goto picker or the history palette in a window",
            .usage = "telar client open goto|history --client ID [--json] [--socket PATH]",
            .routed = &.{ .client_open_goto, .client_open_history },
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  goto             The pane/tab/workspace picker (`applied`).
                \\  history          The command history palette with its initial query queued
                \\                   (`admitted`; results arrive asynchronously).
                \\
                \\{s}
                \\
            , .{routed_text}),
            .examples = &.{ &.{ "client", "open", "goto", "--client", "1" }, &.{ "client", "open", "history", "--client", "1", "--json" } },
        },
        .{
            .name = "copy-mode",
            .summary = "Enter copy mode in a window's focused terminal pane",
            .usage = "telar client copy-mode --client ID [--json] [--socket PATH]",
            .routed = &.{.client_copy_mode},
            .text = std.fmt.comptimePrint(
                \\{s}
                \\
                \\Already in copy mode is a successful no-op; a pane that cannot enter it refuses.
                \\
            , .{routed_text}),
            .examples = &.{&.{ "client", "copy-mode", "--client", "1" }},
        },
        .{
            .name = "open-link",
            .summary = "Open a URI through a window: files in an editor tab, web links in the host's browser",
            .usage = "telar client open-link URI --client ID [--json] [--socket PATH]",
            .routed = &.{.client_open_link},
            .text = std.fmt.comptimePrint(
                \\{s}
                \\
                \\The URI is validated and routed by the window's link policy relative to its
                \\focused pane; `admitted` means the opening job was queued.
                \\
            , .{routed_text}),
            .examples = &.{&.{ "client", "open-link", "https://example.com", "--client", "1" }},
        },
        .{
            .name = "clipboard",
            .summary = "Put text on the clipboard of a window's host",
            .usage = "telar client clipboard copy TEXT --client ID [--json] [--socket PATH]",
            .routed = &.{.client_clipboard_copy},
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  TEXT             UTF-8, at most {d} bytes.
                \\
                \\{s}
                \\
                \\The host writes its clipboard asynchronously, so the answer is `admitted`.
                \\
            , .{ core.ClientCommand.capacity, routed_text }),
            .examples = &.{&.{ "client", "clipboard", "copy", "copied text", "--client", "1" }},
        },
    },
};
