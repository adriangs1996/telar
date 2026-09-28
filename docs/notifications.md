# Notifications

Telar exposes one notification path for the CLI, Lua configuration, and Lua
plugins. A request enters the runtime over the local protocol, the runtime
validates its bounds and broadcasts it, and each connected UI client copies it
into disposable toast state. Notifications are not persisted and never become
runtime lifecycle state.

Routine lifecycle changes are intentionally silent. Creating, renaming, or
closing panes, tabs, and workspaces does not create a toast, and neither does a
pane process exiting. The UI state itself confirms those changes. Request
failures, actionable agent transitions, explicit notifications, and the TLS
interception indicator remain visible.

Agent transition sounds use a separate bounded semantic event. The runtime,
which owns agent truth, emits it only for `working -> ready` and
`working -> blocked`. The event carries the pane ID and generation. A client
discards it when that identity is absent from `ClientModel`'s current agent
snapshot, then applies its local `client.sound` policy.

The runtime offers the event to every active UI client. Each client validates
the pane identity and applies its own profile, so a remote profile can mute
sounds without changing the runtime or another attached client. The complete
worker lifecycle is documented in [Agent sound](flows/agent-sound.md).

## Delivery channels

`config.client.notifications = { delivery = "telar" | "system" }` chooses
where a published notice is surfaced besides the in-app center, which always
shows it. `telar` adds nothing to the center. `system` posts through the
operating system (`osascript` on macOS, `notify-send` on Linux) from a bounded
worker with a three-second timeout; titles and messages are sanitized before
they reach it. Each client applies its own policy, like sounds.

`terminal`, which sent OSC 9 to the terminal client's outer terminal, left
with that client. The window and the headless client have no outer terminal,
so a configuration that still names it loads with the default `telar`
delivery and a notice naming the ignored key (see
[retired keys](configuration.md#retired-keys)).

## CLI

```sh
telar notification show "Build complete" \
  --body "Open the pane" \
  --level success \
  --duration 5000 \
  --pane 42
```

The title is required. `--body` is optional; `--level` accepts `info`,
`success`, `warning`, or `failure`; `--duration` accepts 500 through 60000
milliseconds. `--pane ID`, `--tab ID`, and `--workspace ID` are mutually
exclusive click targets. `--link URL` makes a click open an https URL of at
most 1024 bytes in the browser, through the same policy as a link clicked in
a pane; `telar machine setup` uses it to bring an agent's login page from
another machine to this window. The body holds 192 bytes, too few for an
OAuth URL, so the link travels in its own field. Only the CLI sends one: a
client's own notification requests never carry a link, which keeps the
client's outbox slots small.

Any process that can reach a runtime can send a link, so the link is held
to what a card can show honestly (`core.notification_link`): its authority
is a plain host of letters, digits, dots and hyphens, with no user info
(`https://claude.ai@evil.example/` opens evil.example), no port, no
percent-encoding and no backslash. The card names that host on its action
line, "Open auth.openai.com ↗", before anyone clicks; a host too long for
the card keeps its end, where the domain that owns it is. A window takes
links only from this machine's runtime: a notification from a remote
machine's runtime arrives without its link, so a process on another machine
cannot put a page of its choosing one click away in this machine's browser.
Setup announces a login through the local runtime for that reason.
"Remote" means a connection the client made over SSH itself (`--remote`, a
saved machine). A connection it believes local, or one with no machine,
keeps its links even when its socket is forwarded from another machine by
hand (`ssh -L` to a local path, then `--socket`): the client cannot tell,
so whoever forwards a runtime also trusts the links its processes send. `--socket PATH` selects an explicit runtime; otherwise
the normal `TELAR_SOCKET` and managed-runtime resolution applies.

The command exits successfully only when at least one UI client accepted the
notification. It reports an error when no UI is connected instead of claiming
that an invisible notification was shown. It also does not start an idle
runtime merely to report that no UI exists.

## Lua and plugins

Configuration callbacks return a semantic notification effect:

```lua
return telar.action.notification({
  title = "Agent waiting",
  body = "Review its question",
  level = "warning",
  duration_ms = 4000,
  pane_id = ctx.focused_pane_id,
})
```

A plugin returns the same value from one of its actions and declares the
`notifications` capability in `plugin.json`:

```json
{
  "capabilities": ["notifications"]
}
```

The exact package digest must also be trusted for that capability:

```sh
telar plugin trust ./my-plugin --capability notifications
```

Plugin workers never receive the runtime socket. Their bounded binary result
is decoded and authorized by the client broker, which emits the runtime request
only after the whole effect batch passes validation.

## Bounds and interaction

Titles are limited to 48 UTF-8 bytes, bodies to 192 bytes, and each client
keeps at most four notifications. A fifth replaces the oldest. The native GUI
shows at most two cards at a time, newest first, and suppresses a card whose
target pane is already visible in the active tab. Items outside the visible
set retain their original expiry time. Cards can be dismissed explicitly;
targets use semantic IDs, so a pane, tab, or workspace that disappeared before
the click is safely ignored.

### Native GUI presentation

GUI cards use proportional typography, rounded surfaces, a severity icon and
a close control. Their width is capped at 360 logical chrome pixels. The body
wraps to three lines at word or grapheme boundaries and truncates with an
ellipsis. A targeted card displays an explicit action such as "Open pane".
The layout scales with GUI chrome metrics and fits the workbench viewport.

Entry and exit translate and fade the whole card over 200 ms, keeping its
text layout fixed. Stack positions interpolate over 180 ms when notices are
added or removed. The window's frame clock samples current monotonic time and
requests frames only while visible cards move. The shared notification timer
wakes only at lifecycle boundaries, because the window reports no host
animation frame interval. Neither animation stores a queue of missed frames.

The widget dispatcher registers card and close bounds in device pixels, with
accessible labels and keyboard focus. It publishes them only after successful
frame delivery, retains pointer capture through release, and blocks them
behind a modal. Drawing borrows the shared notification snapshot without
changing it; all stack motion belongs to the disposable GUI connection.

## Agent sound playback

Playback belongs to the client because the runtime may be headless or on a
different machine. It runs as an observation task and never delays input,
rendering, PTY traffic, or another client. Each client keeps at most one sound
in flight and one coalesced successor; a needs-input sound wins over a ready
sound in the same burst.

The [Agent sound flow](flows/agent-sound.md) records the exact identity gate,
configuration replacement, host adapters, process bounds and failure policy.
