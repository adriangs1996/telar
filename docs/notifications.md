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
discards it when that identity is absent from its current agent snapshot, then
applies its local `client.sound` policy.

The runtime offers the event to every active UI client. Each client validates
the pane identity and applies its own profile, so a remote profile can mute
sounds without changing the runtime or another attached client.

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
exclusive click targets. `--socket PATH` selects an explicit runtime; otherwise
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
keeps at most four notifications. A fifth replaces the oldest. Toasts animate
in and out on a continuous smoothstep curve sampled at the client's frame
cadence. Their duration is time-based, so dropped frames do not stretch the
transition; once stable, the client sleeps until the next expiry instead of
polling. Toasts can be dismissed explicitly, and click targets are semantic
IDs; a pane, tab, or workspace that disappeared before the click is safely
ignored.

## Agent sound playback

Playback belongs to the client because the runtime may be headless or on a
different machine. It runs as an observation task and never delays input,
rendering, PTY traffic, or another client. Each client keeps at most one sound
in flight and one coalesced successor; a needs-input sound wins over a ready
sound in the same burst.

On macOS Telar uses `afplay` with the system Glass and Ping sounds. On Windows
it uses `MessageBeep`. On Linux it first asks `canberra-gtk-play` for the
Freedesktop `complete` or `dialog-warning` event, then tries `paplay`,
`pw-play`, `ffplay`, and `mpv` with the corresponding Freedesktop sound file.
Missing players, missing sound files, and playback errors leave the visual
notification intact and do not affect the client.

## Rendering

When the client has confirmed Kitty Graphics support and knows the host cell
size, it shapes UTF-8 with HarfBuzz and rasterizes the resulting glyphs into
RGBA with FreeType and the embedded JetBrains Mono face. Cell composition first
records a fixed-size media plan and flushes the cell fallback. Rasterization is
deferred to a lower-priority media pass after host input has been quiet for 250
ms. A texture is regenerated only when its content, theme, or pixel geometry
changes; the 200 ms transition updates only a native-size KGP source crop and
placement, so the smoothstep curve keeps pixel precision instead of snapping to
columns.

The renderer owns at most four 1.5 MiB images. It transmits one texture at a
time and emits at most 256 KiB of encoded KGP data per media pass, so a texture
larger than that budget is continued over several passes. Until every visible
image has reached the host, the whole stack remains cell-rendered. Unsupported
KGP, terminal-derived colors, missing glyphs, oversized geometry, allocation
failure, resize, and renderer initialization failure all take the same path:
remove graphical placements and keep the clickable cell renderer. The hit
targets remain cell-owned even while KGP supplies the pixels. Debug telemetry
reports the cache as `toast_cache_bytes` and attributes its wire traffic to
`toast_graphics_flushed_bytes` and `media_flush_*` rather than cell `flush_*`.
