# Terminal colors

The window tells the runtime its theme's default colors. The runtime uses
those values as Ghostty VT defaults for panes controlled by that client, so a
child that queries OSC 10 or OSC 11 gets the colors the window draws with.
This does not convert default cell colors to RGB.

## Ownership and flow

The window's renderer theme is the source. There is no exterior terminal to
probe; the terminal client's OSC 10/11 host probes left with it.

```text
GuiAdapter.windowReady -> start(theme foreground, background, palette)
  -> host_resize.applyHostUpdate (capabilities.terminal_colors)
  -> client.bootstrap.terminal_colors
  -> runtime_link: configure_graphics
  -> configure_terminal_colors
  -> request_runtime_state
  -> existing client_layout_snapshot / open_pane flow

theme reload or resize
  -> GuiAdapter.resize -> host_resize.applyHostUpdate
  -> host_resize.deliverHostCommit: colors changed, startup opening or active
  -> configure_terminal_colors
```

The three bootstrap messages use the ordinary FIFO outbox and its send actor.
No synchronous socket write competes with that actor. The headless client
bootstraps with unknown colors.

The client model retains the RGB values in
`model.host.host_capabilities.terminal_colors`.
Its existing host transaction detects changes without color-specific revision
logic. `host_resize.deliverHostCommit` publishes a later change once startup
is opening or active. `appearance` remains a separate derived value used to
select the client UI theme.

## Runtime authority

`client_request.receive` calls `terminal_colors.configure`
in the runtime. That concrete operation commits the session's colors before
updating any workspace. The runtime
checks existing geometry ownership without acquiring a lease on behalf of a
spectator. A new lease applies the new owner's defaults to existing panes.
`pane_launch.launch` selects that owner's colors for every launch path,
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
child escape sequences to the host.

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

- Fixed-size copies through the existing bounded outbox and client store.
- One pending color update per pane, with no allocation or extra worker.
- Unknown colors remain unknown.
- Client failure cancels its reads before freeing their buffers. Runtime
  processes remain alive.

A process relaunched by checkpoint recovery can start without any connected
client. It has no known host colors until a client acquires its workspace.
Colors are not added to persistence by this change. Updating terminal defaults
also cannot force an already-running application to discard a cached failed
color query.

## Validation

- PTY integration through `zig build run --color on` and `--color off`: neither
  mode injects color overrides; panes retain `COLORTERM=truecolor` and answer
  OSC 10/11. Explicit user overrides remain unchanged. With no override,
  Codex 0.153.4 emits the RGB input background; `CLICOLOR_FORCE=1` reproduces
  its missing background with the same colors.
- `src/model/connection/Outbox.zig`: the exact three-frame bootstrap order.
- `src/gui/tests/configuration.zig`: a theme reload commits the new terminal
  colors to the host capabilities.
- `src/backend/pane/pane_namespace.zig`: child query fragments, overrides, resets and deferred
  latest-value updates during ingestion.
- `lib/vtgrid/blit.zig`: semantic defaults and explicit RGB cell backgrounds.
- `src/backend/runtime/terminal_colors.zig` and `src/backend/runtime/geometry_lease.zig`: ownership, spectators, lease transfer,
  disconnect retention and generation-safe lookup.
- `src/core/schema_contract_test.zig`: wire fingerprint, truncation, optional colors
  and malformed presence flags.
