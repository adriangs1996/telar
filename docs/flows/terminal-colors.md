# Terminal colors

The client queries its exterior terminal with OSC 10 and OSC 11. The runtime
uses those values as Ghostty VT defaults for panes controlled by that client.
This does not convert default cell colors to RGB and does not change host
transparency.

## Ownership and flow

`controllers/host/host_capabilities.zig` owns issuing host probes, translating
replies and settling expiry. `resources/host_negotiation.zig` retains one
250 ms probe window, records each color once and rejects unsolicited or expired
color reports. Resizes always refresh pixel geometry; overlapping color probes
are coalesced. OSC replies have no request IDs, so a report is correlated only
by color target and the current non-overlapping window.

```text
client_startup.start
  -> host probes + the existing TTY read
  -> OSC 10/11 replies or deadline
  -> client_startup.advance
  -> configure_graphics
  -> configure_terminal_colors
  -> request_runtime_state
  -> existing client_layout_snapshot / open_pane flow
```

Startup dispatches its buffered host probes through the single-flight output
owner before awaiting the first event. Flushing the staging writer alone does
not deliver bytes to the host. The async-output startup test verifies a pending
host write with no bootstrap message sent and no consumed event.

The three bootstrap messages use the ordinary FIFO outbox and its send actor.
No synchronous socket write competes with that actor. Color readiness does not
wait for graphics support. Before the first pane is activated,
`resources/startup_input.zig` uses the presentation parser to deliver host
responses and retains other input. It preserves bracketed paste as data and
replays unfinished escape prefixes through the normal input router.

The client model retains the RGB values in `HostCapabilities.terminal_colors`.
Its existing host transaction detects changes without color-specific revision
logic. Later color changes publish the same `configure_terminal_colors` message
through host-resource delivery. `appearance` remains a separate derived value
used to select the client UI theme.

## Runtime authority

The request controller delegates to the terminal-colors command handler. The
handler commits the session's colors before updating any workspace. The runtime
checks existing geometry ownership without acquiring a lease on behalf of a
spectator. A new lease applies the new owner's defaults to existing panes.
`Application.launchPane` selects that owner's colors for every launch path,
before `Pane.create` spawns the process.

Each pane retains its applied defaults after client disconnection. A transfer
uses the new owner's values, including unknown values. Spectators never replace
another client's pane defaults. A stale client generation cannot select the
current session's values.

`Pane.setTerminalColors` updates only `DynamicRGB.default`. Child overrides
remain authoritative; OSC 110/111 removes the override and exposes the current
default. During an active VT ingest, the pane retains one latest-value update.
`completeOutputIngest` applies it after releasing actor ownership. Coordinators
and launch commands do not know the color-update protocol.

The emulator parses and answers child OSC queries itself. Telar does not forward
child escape sequences to the exterior terminal.

## Development launch environment

`zig build run`, including `just r`, uses `Run.color = .manual`. The build
runner must not inject `CLICOLOR_FORCE` or `NO_COLOR` into Telar. Explicit
user values still pass through unchanged.

This matters independently of OSC replies. Codex 0.153.4 treats
`CLICOLOR_FORCE=1` as a 16-color override and drops its RGB input background,
even with `COLORTERM=truecolor` and successful OSC 10/11 queries. Zig's default
run-step color policy injects that variable when build output uses color.

A runtime retains its launch environment. After changing this build setting,
restart the development runtime with `just stop`, then `just r`. Stopping the
runtime terminates its live pane processes; rebuilding or reattaching alone
does not replace their environment.

## Bounds and failure

- One replaceable timer task and one color probe window per client.
- Two optional RGB values in the wire message, at most nine bytes including tag.
- Eight KiB of retained startup input and four KiB for a partial sequence.
  Saturation returns `StartupInputOverflow`; input is never silently dropped.
- Fixed-size copies through the existing bounded outbox and client store.
- One pending color update per pane, with no allocation or extra worker.
- Unknown colors remain unknown. Missing host replies cannot hold client startup
  beyond the probe deadline.
- Client failure cancels its reads and timer before freeing their buffers.
  Runtime processes remain alive.

A process relaunched by checkpoint recovery can start without any connected
client. It has no known host colors until a client acquires its workspace.
Colors are not added to persistence by this change. Updating terminal defaults
also cannot force an already-running application to discard a cached failed
color query.

## Proof

- PTY integration through `zig build run --color on` and `--color off`: neither
  mode injects color overrides; panes retain `COLORTERM=truecolor` and answer
  OSC 10/11. Explicit user overrides remain unchanged. With no override,
  Codex 0.153.4 emits the RGB input background; `CLICOLOR_FORCE=1` reproduces
  its missing background with the same host color replies.
- `resources/host_negotiation.zig`: deadline, duplicate replies and probe overlap.
- `resources/startup_input.zig`: fragmented replies, preserved typing, paste,
  partial escapes and explicit saturation failure.
- `presentation/screen.zig`: OSC 10/11 parsing, terminators and malformed RGB.
- `client/tests/transport.zig`: ordered bootstrap, timeout fallback and replay
  only after pane activation.
- `backend/pane/root.zig`: child query fragments, overrides, resets and deferred
  latest-value updates during ingestion.
- `backend/pane/blit.zig`: semantic defaults and explicit RGB cell backgrounds.
- `backend/runtime/application/root.zig`: ownership, spectators, lease transfer,
  disconnect retention and generation-safe lookup.
- `core/schema_contract_test.zig`: wire fingerprint, truncation, optional colors
  and malformed presence flags.
